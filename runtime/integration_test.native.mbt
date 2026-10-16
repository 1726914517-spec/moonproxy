///|
// Native end-to-end tests: real backends, a real proxy and a real HTTP client
// over localhost sockets. These prove the portable decision core and the
// socket runtime meet on the wire.

async fn test_backend(port : Int, name : String) -> Unit {
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
