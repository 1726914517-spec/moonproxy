///|
// The native proxy runtime: an L7 reverse proxy. For each accepted request it
// selects a route by host/path, chooses a backend through the pool's balancer,
// translates and forwards the request, streams the response back, and fails
// over to a healthy peer when safe. This file is native-only — real sockets
// come from `moonbitlang/async`'s native FFI.

///|
/// The outcome of one attempt to reach a backend.
priv enum Forward {
  /// The response was (or is being) streamed to the client.
  Delivered
  /// The connection could not be established or the request headers sent; safe
  /// to try another backend.
  ConnectFailed
  /// A failure after the request body was (partly) sent; not safely replayable.
  BodyFailed
  /// The backend answered with a retryable status for an idempotent method.
  RetryableStatus
}

///|
/// A running proxy over a static configuration, holding one balancer per pool
/// (so each pool's round-robin/weighted state persists) and the health policy.
pub struct Runtime {
  config : @moonproxy.ProxyConfig
  balancers : Map[String, @moonproxy.Balancer]
  health : @moonproxy.HealthPolicy
}

///|
/// Build a runtime; the health policy defaults to a threshold of 2.
pub fn Runtime::new(
  config : @moonproxy.ProxyConfig,
  health? : @moonproxy.HealthPolicy = @moonproxy.HealthPolicy::new(),
) -> Runtime {
  let balancers : Map[String, @moonproxy.Balancer] = Map([])
  { config, balancers, health, }
}

///|
/// Get the persistent balancer for a pool, creating it from the pool's policy.
fn Runtime::balancer_for(
  self : Runtime,
  pool : @moonproxy.BackendPool,
) -> @moonproxy.Balancer {
  let id = pool.id()
  match self.balancers.get(id) {
    Some(b) => b
    None => {
      let b = @moonproxy.Balancer::new(policy=pool.policy())
      self.balancers.set(id, b)
      b
    }
  }
}

///|
/// Bind the listener and serve until cancelled.
pub async fn Runtime::serve(self : Runtime) -> Unit {
  let addr = @socket.Addr::parse(self.config.bind())
  let server = @http.Server(addr, reuse_addr=true)
  let rt = self
  server.run_forever(
    (req, body, conn) => {
      rt.handle(req, body, conn) catch {
        _ => {
          conn.send_response(502, "Bad Gateway") catch {
            _ => ()
          }
          conn.end_response() catch {
            _ => ()
          }
        }
      }
    },
    allow_failure=true,
  )
}

///|
async fn Runtime::handle(
  self : Runtime,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let original_host = match header_value(req.headers, "host") {
    Some(h) => h
    None => ""
  }
  let host = @moonproxy.normalize_host(original_host)
  match @moonproxy.select_route(self.config.routes(), host, req.path) {
    None => {
      conn.send_response(404, "Not Found")
      conn.end_response()
    }
    Some(route) => self.proxy_to_route(route, req, body, conn, original_host)
  }
}

///|
async fn send_bad_gateway(conn : @http.ServerConnection) -> Unit {
  conn.send_response(502, "Bad Gateway")
  conn.end_response()
}

///|
async fn Runtime::proxy_to_route(
  self : Runtime,
  route : @moonproxy.Route,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
  original_host : String,
) -> Unit {
  let pool = route.pool()
  let backends = pool.backends()
  let bal = self.balancer_for(pool)
  let client_ip = ip_of(conn.client_addr())
  let meth = method_to_string(req.meth)
  let opts = route.options()
  let incoming = headers_to_pairs(req.headers)
  let tried : Array[Int] = []
  let mut done = false
  while !done {
    match @moonproxy.pick(bal, backends, client_key=client_ip, exclude=tried) {
      None => {
        send_bad_gateway(conn)
        done = true
      }
      Some(idx) => {
        tried.push(idx)
        @moonproxy.acquire(backends, idx)
        let outcome = forward_one(
          route,
          req,
          body,
          conn,
          backends[idx],
          incoming,
          client_ip,
          original_host,
          meth,
        )
        @moonproxy.release(backends, idx)
        match outcome {
          Delivered => {
            @moonproxy.record_success(backends, idx, self.health)
            done = true
          }
          ConnectFailed => {
            @moonproxy.record_failure(backends, idx, self.health)
            if !opts.failover {
              send_bad_gateway(conn)
              done = true
            }
          }
          BodyFailed => {
            send_bad_gateway(conn)
            done = true
          }
          RetryableStatus => {
            @moonproxy.record_failure(backends, idx, self.health)
            if !opts.failover {
              send_bad_gateway(conn)
              done = true
            }
          }
        }
      }
    }
  }
}

///|
async fn forward_one(
  route : @moonproxy.Route,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
  backend : @moonproxy.Backend,
  incoming : Array[(String, String)],
  client_ip : String,
  original_host : String,
  meth : String,
) -> Forward {
  let opts = route.options()
  let upstream_host = backend.address()
  let url = backend.origin()
  let req_headers = @moonproxy.forward_request_headers(
    incoming, client_ip, "http", original_host, upstream_host, opts,
  )

  // Phase A: dial and send the request line + headers. The async client always
  // emits its own `Host` (the dialed upstream address) and a `User-Agent`; we
  // hand it the real client User-Agent as a default header (respected once) and
  // drop both names from the per-request extras so nothing is sent twice. A
  // failure here means nothing reached the backend, so another can be tried.
  let default_pairs : Array[(String, String)] = []
  for (k, v) in incoming {
    if k == "user-agent" {
      default_pairs.push((k, v))
    }
  }
  let client = @http.Client(url, headers=to_ci_map(default_pairs)) catch {
    _ => return ConnectFailed
  }
  let pass_headers : Array[(String, String)] = []
  for (k, v) in req_headers {
    if k != "host" && k != "user-agent" {
      pass_headers.push((k, v))
    }
  }
  client.request(req.meth, req.path, extra_headers=to_ci_map(pass_headers)) catch {
    _ => {
      client.close()
      return ConnectFailed
    }
  }

  // Phase B: stream the request body. The reader is consumed, so a failure
  // mid-body cannot be replayed on another backend.
  client.write_reader(body) catch {
    _ => {
      client.close()
      return BodyFailed
    }
  }

  // Phase C: finish the request and read the upstream status/headers.
  let resp = client.end_request() catch {
    _ => {
      client.close()
      return BodyFailed
    }
  }

  // A retryable status from an idempotent method: let the loop try a peer.
  if opts.failover && @moonproxy.can_retry_status(meth, resp.code) {
    client.close()
    return RetryableStatus
  }

  // Final answer: translate the response headers and stream the body back.
  let resp_pairs = headers_to_pairs(resp.headers)
  let out_headers = @moonproxy.forward_response_headers(resp_pairs)
  conn.send_response(
    resp.code,
    resp.reason,
    extra_headers=to_ci_map(out_headers),
  )
  conn.write_reader(client)
  conn.end_response()
  Delivered
}
