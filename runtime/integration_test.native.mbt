///|
// Native end-to-end tests: real backends, a real proxy and a real HTTP client
// over localhost sockets. These prove the portable decision core and the
// socket runtime meet on the wire.

async fn test_backend(port : Int32, name : String) -> Unit {
  let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string())
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever(
    (req, _body, conn) => {
      let xff = match
        req.headers.get(@http.CaseInsensitiveString("x-forwarded-for")) {
        Some(v) => v
        None => "-"
      }
      let extra = Map([
        (@http.CaseInsensitiveString("content-type"), "text/plain"),
        (@http.CaseInsensitiveString("x-served-by"), name),
        (@http.CaseInsensitiveString("x-seen-xff"), xff),
      ])
      conn.send_response(200, "OK", extra_headers=extra)
      conn.write_string(name)
      conn.end_response()
    },
    allow_failure=true,
  )
}

///|
fn test_config() -> @moonproxy.ProxyConfig {
  let web = @moonproxy.BackendPool::new("web", policy=@moonproxy.RoundRobin)
    .add(@moonproxy.Backend::new("127.0.0.1", 18601))
    .add(@moonproxy.Backend::new("127.0.0.1", 18602))
  let api = @moonproxy.BackendPool::new("api")
    .add(@moonproxy.Backend::new("127.0.0.1", 18601))
    .add(@moonproxy.Backend::new("127.0.0.1", 18699)) // nothing listens
  @moonproxy.ProxyConfig::new(host="127.0.0.1", port=18680)
  .add_route(@moonproxy.Route::prefix("api", "/api", api))
  .add_route(@moonproxy.Route::prefix("root", "/", web))
}

///|
fn probe_config() -> @moonproxy.ProxyConfig {
  let only = @moonproxy.BackendPool::new("only").add(
    @moonproxy.Backend::new("127.0.0.1", 18710),
  )
  @moonproxy.ProxyConfig::new(host="127.0.0.1", port=18780).add_route(
    @moonproxy.Route::prefix("root", "/", only),
  )
}

///|
async test "runtime: active probe revives a backend after it comes back" {
  @async.with_task_group(g => {
    // A single-backend pool with threshold 1: one failed exchange trips it and
    // one successful probe brings it back.
    let health = @moonproxy.HealthPolicy::new(
      unhealthy_threshold=1,
      healthy_threshold=1,
    )
    let runtime = @runtime.Runtime::new(probe_config(), health~)
    let tproxy = g.spawn(() => runtime.serve())
    let tprobe = g.spawn(() => runtime.run_probes(interval_ms=100))
    @async.sleep(400)

    // The backend is not running yet. A request fails and trips it out of
    // rotation, so the proxy answers 502 while nothing is healthy.
    let (down_resp, _db) = @http.get("http://127.0.0.1:18780/")
    assert_eq(down_resp.code, 502)

    // Now start the backend. The active probe loop (every 100ms) should dial
    // it, observe success and bring it back without any client traffic.
    let tbackend = g.spawn(() => test_backend(18710, "revived"))
    @async.sleep(800)

    let (up_resp, _ub) = @http.get("http://127.0.0.1:18780/")
    assert_eq(up_resp.code, 200)
    assert_eq(up_resp.headers.get("x-served-by"), Some("revived"))

    tbackend.cancel()
    tproxy.cancel()
    tprobe.cancel()
  })
}

///|
async test "runtime: balances over backends, forwards XFF and fails over" {
  @async.with_task_group(g => {
    let t1 = g.spawn(() => test_backend(18601, "backend-1"))
    let t2 = g.spawn(() => test_backend(18602, "backend-2"))
    let runtime = @runtime.Runtime::new(test_config())
    let t3 = g.spawn(() => runtime.serve())
    @async.sleep(400)

    let seen : Array[String] = []
    for _ in 0..<4 {
      let (resp, _body) = @http.get("http://127.0.0.1:18680/")
      assert_eq(resp.code, 200)
      match resp.headers.get("x-served-by") {
        Some(name) => if !seen.contains(name) { seen.push(name) }
        None => ()
      }
      // The proxy added X-Forwarded-For; the backend echoes what it received.
      assert_eq(resp.headers.get("x-seen-xff"), Some("127.0.0.1"))
    }
    // Round-robin spread traffic across both backends.
    assert_eq(seen.contains("backend-1"), true)
    assert_eq(seen.contains("backend-2"), true)

    // Failover: the api pool has a dead backend, yet the request succeeds.
    let (api_resp, _b) = @http.get("http://127.0.0.1:18680/api/users")
    assert_eq(api_resp.code, 200)

    // Stop the long-lived servers so the task group can finish.
    t1.cancel()
    t2.cancel()
    t3.cancel()
  })
}

///|
// A backend that echoes the received request target in a header.
async fn echo_path_backend(port : Int32) -> Unit {
  let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string())
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever(
    (req, _body, conn) => {
      let extra = Map([(@http.CaseInsensitiveString("x-seen-path"), req.path)])
      conn.send_response(200, "OK", extra_headers=extra)
      conn.write_string("ok")
      conn.end_response()
    },
    allow_failure=true,
  )
}

///|
fn exact_route_config() -> @moonproxy.ProxyConfig {
  let pool = @moonproxy.BackendPool::new("exact").add(
    @moonproxy.Backend::new("127.0.0.1", 18801),
  )
  @moonproxy.ProxyConfig::new(host="127.0.0.1", port=18880).add_route(
    @moonproxy.Route::exact("users", "/users", pool),
  )
}

///|
async test "runtime: exact route matches when a query string is present" {
  @async.with_task_group(g => {
    let tbackend = g.spawn(() => echo_path_backend(18801))
    let runtime = @runtime.Runtime::new(exact_route_config())
    let tproxy = g.spawn(() => runtime.serve())
    @async.sleep(400)

    // The query string must not break exact matching, and the full target is
    // still forwarded so the backend sees the query.
    let (resp, _body) = @http.get("http://127.0.0.1:18880/users?id=1")
    assert_eq(resp.code, 200)
    assert_eq(resp.headers.get("x-seen-path"), Some("/users?id=1"))

    // The exact path itself still matches.
    let (plain, _pb) = @http.get("http://127.0.0.1:18880/users")
    assert_eq(plain.code, 200)

    // An unrelated path still 404s.
    let (other, _ob) = @http.get("http://127.0.0.1:18880/other")
    assert_eq(other.code, 404)

    tbackend.cancel()
    tproxy.cancel()
  })
}

///|
// A backend that sets two cookies on every response.
async fn cookie_backend(port : Int32) -> Unit {
  let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string())
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever(
    (_req, _body, conn) => {
      let cookies = [@http.Cookie("sid", "abc"), @http.Cookie("track", "xyz")]
      conn.send_response(200, "OK", cookies~)
      conn.write_string("ok")
      conn.end_response()
    },
    allow_failure=true,
  )
}

///|
fn cookie_config() -> @moonproxy.ProxyConfig {
  let pool = @moonproxy.BackendPool::new("cookies").add(
    @moonproxy.Backend::new("127.0.0.1", 18802),
  )
  @moonproxy.ProxyConfig::new(host="127.0.0.1", port=18881).add_route(
    @moonproxy.Route::prefix("root", "/", pool),
  )
}

///|
async test "runtime: forwards upstream Set-Cookie headers" {
  @async.with_task_group(g => {
    let tbackend = g.spawn(() => cookie_backend(18802))
    let runtime = @runtime.Runtime::new(cookie_config())
    let tproxy = g.spawn(() => runtime.serve())
    @async.sleep(400)

    let (resp, _body) = @http.get("http://127.0.0.1:18881/")
    assert_eq(resp.code, 200)
    assert_eq(resp.cookies.length(), 2)
    let names : Array[String] = []
    for c in resp.cookies {
      names.push(c.name)
    }
    assert_eq(names.contains("sid"), true)
    assert_eq(names.contains("track"), true)

    tbackend.cancel()
    tproxy.cancel()
  })
}

///|
// A PUT backend that drains the body, records "name:body-length" in the shared
// log and answers 500 when `fail`, 200 otherwise.
async fn put_backend(
  port : Int32,
  name : String,
  fail : Bool,
  log : Array[String],
) -> Unit {
  let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string())
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever(
    (req, body, conn) => {
      if req.meth == @http.Put {
        let payload = body.read_all()
        log.push(name + ":" + payload.binary().length().to_string())
        if fail {
          conn.send_response(500, "Internal Server Error")
          conn.end_response()
        } else {
          conn.send_response(200, "OK")
          conn.write_string("ok")
          conn.end_response()
        }
      } else {
        conn.send_response(200, "OK")
        conn.end_response()
      }
    },
    allow_failure=true,
  )
}

///|
fn put_retry_config() -> @moonproxy.ProxyConfig {
  let pool = @moonproxy.BackendPool::new("put")
    .add(@moonproxy.Backend::new("127.0.0.1", 18803))
    .add(@moonproxy.Backend::new("127.0.0.1", 18804))
  @moonproxy.ProxyConfig::new(host="127.0.0.1", port=18882).add_route(
    @moonproxy.Route::prefix("root", "/", pool),
  )
}

///|
async test "runtime: does not retry after the request body was sent" {
  @async.with_task_group(g => {
    let log : Array[String] = []
    // The first backend (index 0, round-robin) fails with 500; the peer would
    // answer 200. Both share the contact log.
    let tfail = g.spawn(() => put_backend(18803, "A", true, log))
    let tok = g.spawn(() => put_backend(18804, "B", false, log))
    let runtime = @runtime.Runtime::new(put_retry_config())
    let tproxy = g.spawn(() => runtime.serve())
    @async.sleep(400)

    let content = b"payload-data"
    let (resp, _body) = @http.put("http://127.0.0.1:18882/resource", content)
    // The upstream 500 is passed through, not hidden behind a retried success.
    assert_eq(resp.code, 500)
    // Exactly one backend was contacted: the failing one, with the full body.
    assert_eq(log.length(), 1)
    assert_eq(log[0], "A:" + content.length().to_string())

    tfail.cancel()
    tok.cancel()
    tproxy.cancel()
  })
}
