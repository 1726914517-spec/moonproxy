///|
// The native proxy runtime: an L7 reverse proxy. For each accepted request it
// selects a route by host/path, chooses a backend through the pool's balancer,
// translates and forwards the request, streams the response back, and fails
// over to a healthy peer when safe. Edge governance (per-client rate limiting,
// request body size) and structured access logging wrap the forwarding path.
// This file is native-only — real sockets come from `moonbitlang/async`.

///|
/// The outcome of one attempt to reach a backend. `Delivered` carries the
/// upstream status code; the other variants describe a failure and whether it
/// is safe to retry.
priv enum Forward {
  /// The response was (or is being) streamed to the client.
  Delivered(Int32)
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
/// (so each pool's round-robin/weighted state persists), the health policy, an
/// optional per-client rate limiter and the access log sink.
pub struct Runtime {
  config : @moonproxy.ProxyConfig
  balancers : Map[String, @moonproxy.Balancer]
  health : @moonproxy.HealthPolicy
  limiter : @moonproxy.RateLimiter?
  sink : LogSink
}

///|
/// Build a runtime; the health policy defaults to a threshold of 2 and the
/// access log sink to JSON lines on stdout.
pub fn Runtime::new(
  config : @moonproxy.ProxyConfig,
  health~ : @moonproxy.HealthPolicy = @moonproxy.HealthPolicy::new(),
  sink~ : LogSink = LogSink::Stdout,
) -> Runtime {
  let balancers : Map[String, @moonproxy.Balancer] = Map([])
  let limiter = match config.governance().rate_limit() {
    Some(rule) => Some(@moonproxy.RateLimiter::new(rule))
    None => None
  }
  { config, balancers, health, limiter, sink, }
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
      rt.process(req, body, conn) catch {
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
/// One request through the governance wrapper: rate limit, body size limit,
/// then the forwarding path, with a structured access record written in every
/// case (including rejections and errors).
async fn Runtime::process(
  self : Runtime,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let start = @async.now()
  let client_ip = ip_of(conn.client_addr())
  let meth = method_to_string(req.meth)
  let incoming = headers_to_pairs(req.headers)

  // Per-client rate limiting: answer 429 before touching any backend.
  match self.limiter {
    Some(limiter) => {
      let now_ms = @async.now().to_int()
      if !limiter.allow(client_ip, now_ms) {
        let headers = Map([(@http.CaseInsensitiveString("retry-after"), "1")])
        conn.send_response(429, "Too Many Requests", extra_headers=headers)
        conn.end_response()
        self.log(client_ip, meth, req.path, 429, start)
        return
      }
    }
    None => ()
  }

  // Request body size limit: reject an oversized declared body before
  // forwarding (413).
  let max_body = self.config.governance().max_body_bytes()
  if @moonproxy.body_too_large(incoming, max_body) {
    conn.send_response(413, "Payload Too Large")
    conn.end_response()
    self.log(client_ip, meth, req.path, 413, start)
    return
  }

  let status = self.handle(req, body, conn, incoming, client_ip)
  self.log(client_ip, meth, req.path, status, start)
}

///|
/// Build and emit one access record.
fn Runtime::log(
  self : Runtime,
  client_ip : String,
  meth : String,
  path : String,
  status : Int32,
  start : Int64,
) -> Unit {
  let now = @async.now()
  let entry = AccessLogEntry::new(
    timestamp_ms=now,
    client_ip~,
    http_method=meth,
    path~,
    status~,
    latency_ms=now - start,
  )
  self.sink.emit(entry)
}

///|
/// The access records captured when this runtime uses a memory sink; empty for
/// the stdout sink.
pub fn Runtime::access_entries(self : Runtime) -> Array[AccessLogEntry] {
  self.sink.entries()
}

///|
async fn Runtime::handle(
  self : Runtime,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
  incoming : Array[(String, String)],
  client_ip : String,
) -> Int32 {
  let original_host = match header_value(req.headers, "host") {
    Some(h) => h
    None => ""
  }
  let host = @moonproxy.normalize_host(original_host)
  // Route on the path alone; the query string is not part of path matching, but
  // the full target (req.path) is still forwarded to the backend.
  let route_path = @moonproxy.path_only(req.path)
  match @moonproxy.select_route(self.config.routes(), host, route_path) {
    None => {
      conn.send_response(404, "Not Found")
      conn.end_response()
      404
    }
    Some(route) =>
      self.proxy_to_route(
        route, req, body, conn, incoming, client_ip, original_host,
      )
  }
}

///|
async fn send_bad_gateway(conn : @http.ServerConnection) -> Int32 {
  conn.send_response(502, "Bad Gateway")
  conn.end_response()
  502
}

///|
async fn Runtime::proxy_to_route(
  self : Runtime,
  route : @moonproxy.Route,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
  incoming : Array[(String, String)],
  client_ip : String,
  original_host : String,
) -> Int32 {
  let pool = route.pool()
  let backends = pool.backends()
  let bal = self.balancer_for(pool)
  let meth = method_to_string(req.meth)
  let opts = route.options()
  let tried : Array[Int32] = []
  let mut done = false
  let mut final_status = 502
  while !done {
    match @moonproxy.pick(bal, backends, client_key=client_ip, exclude=tried) {
      None => {
        final_status = send_bad_gateway(conn)
        done = true
      }
      Some(idx) => {
        tried.push(idx)
        @moonproxy.acquire(backends, idx)
        @moonproxy.count_request(backends, idx)
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
          Delivered(code) => {
            @moonproxy.record_success(backends, idx, self.health)
            @moonproxy.count_success(backends, idx)
            final_status = code
            done = true
          }
          ConnectFailed => {
            @moonproxy.record_failure(backends, idx, self.health)
            @moonproxy.count_failure(backends, idx)
            if !opts.failover {
              final_status = send_bad_gateway(conn)
              done = true
            }
          }
          BodyFailed => {
            @moonproxy.count_failure(backends, idx)
            final_status = send_bad_gateway(conn)
            done = true
          }
          RetryableStatus => {
            @moonproxy.record_failure(backends, idx, self.health)
            @moonproxy.count_failure(backends, idx)
            if !opts.failover {
              final_status = send_bad_gateway(conn)
              done = true
            }
          }
        }
      }
    }
  }
  final_status
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
  // Whether the request carries a body that will be streamed and consumed. After
  // it is sent, the reader cannot be rewound, so retrying on another backend
  // would replay an empty body.
  let has_body = @moonproxy.request_has_body(incoming)

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

  // A retryable status from an idempotent method is safe only when no body was
  // streamed. With a body the reader is already consumed, so pass the upstream
  // status through rather than replay an empty request on another backend.
  if opts.failover && !has_body && @moonproxy.can_retry_status(meth, resp.code) {
    client.close()
    return RetryableStatus
  }

  // Final answer: translate the response headers, forward upstream cookies and
  // stream the body back. Set-Cookie is delivered through the dedicated cookie
  // channel (the parser keeps it out of the header map).
  let resp_pairs = headers_to_pairs(resp.headers)
  let out_headers = @moonproxy.forward_response_headers(resp_pairs)
  conn.send_response(
    resp.code,
    resp.reason,
    extra_headers=to_ci_map(out_headers),
    cookies=resp.cookies,
  )
  conn.write_reader(client)
  conn.end_response()
  Delivered(resp.code)
}
