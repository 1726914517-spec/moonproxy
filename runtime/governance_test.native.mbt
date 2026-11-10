///|
// Native end-to-end tests for edge governance: per-client rate limiting (429),
// request body size limits (413) and the in-memory access log.

///|
// A backend that drains the body and counts every request it actually receives,
// so a test can prove a rejected request never reached upstream.
async fn counting_backend(port : Int32, count : Array[Int32]) -> Unit {
  let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string())
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever(
    (_req, body, conn) => {
      let _ = body.read_all()
      count.push(1)
      conn.send_response(200, "OK")
      conn.write_string("ok")
      conn.end_response()
    },
    allow_failure=true,
  )
}

///|
// POST with an explicit Content-Length. The convenience `@http.post` puts the
// length through the client constructor, which strips it and falls back to
// chunked encoding; passing it as a per-request extra header keeps the length.
async fn post_with_cl(base_url : String, body : Bytes) -> @http.Response {
  let client = @http.Client(base_url)
  let headers = Map([
    (@http.CaseInsensitiveString("content-length"), body.length().to_string()),
  ])
  client.request(@http.Post, "/", extra_headers=headers)
  client.write(body)
  client.end_request()
}

///|
fn rate_limit_config() -> @moonproxy.ProxyConfig {
  let pool = @moonproxy.BackendPool::new("web").add(
    @moonproxy.Backend::new("127.0.0.1", 18901),
  )
  let rule = @moonproxy.RateLimitRule::new(capacity=2, refill_per_sec=1)
  let governance = @moonproxy.Governance::new(
    rate_limit=Some(rule),
    max_body_bytes=0,
  )
  @moonproxy.ProxyConfig::new(host="127.0.0.1", port=18980, governance~).add_route(
    @moonproxy.Route::prefix("root", "/", pool),
  )
}

///|
async test "runtime: rate limits burst, answers 429, then refills" {
  @async.with_task_group(g => {
    let tbackend = g.spawn(() => counting_backend(18901, []))
    let runtime = @runtime.Runtime::new(
      rate_limit_config(),
      sink=@runtime.LogSink::memory(),
    )
    let tproxy = g.spawn(() => runtime.serve())
    @async.sleep(400)

    let url = "http://127.0.0.1:18980/"
    let (r1, _b1) = @http.get(url)
    let (r2, _b2) = @http.get(url)
    let (r3, _b3) = @http.get(url)
    assert_eq(r1.code, 200)
    assert_eq(r2.code, 200)
    // The burst (capacity 2) is exhausted; the third request is rejected.
    assert_eq(r3.code, 429)
    assert_eq(r3.headers.get("retry-after"), Some("1"))

    // At one token per second, waiting just over a second restores one request.
    @async.sleep(1100)
    let (r4, _b4) = @http.get(url)
    assert_eq(r4.code, 200)

    // The in-memory access log records every exchange with the right fields.
    let entries = runtime.access_entries()
    assert_eq(entries.length(), 4)
    let statuses : Array[Int32] = []
    for e in entries {
      statuses.push(e.status())
      assert_eq(e.http_method(), "GET")
      assert_eq(e.path(), "/")
      assert_eq(e.client_ip(), "127.0.0.1")
    }
    assert_eq(statuses, [200, 200, 429, 200])

    tbackend.cancel()
    tproxy.cancel()
  })
}

///|
fn body_limit_config() -> @moonproxy.ProxyConfig {
  let pool = @moonproxy.BackendPool::new("web").add(
    @moonproxy.Backend::new("127.0.0.1", 18902),
  )
  let governance = @moonproxy.Governance::new(max_body_bytes=10)
  @moonproxy.ProxyConfig::new(host="127.0.0.1", port=18981, governance~).add_route(
    @moonproxy.Route::prefix("root", "/", pool),
  )
}

///|
async test "runtime: rejects oversized bodies with 413 before forwarding" {
  @async.with_task_group(g => {
    let count : Array[Int32] = []
    let tbackend = g.spawn(() => counting_backend(18902, count))
    let runtime = @runtime.Runtime::new(
      body_limit_config(),
      sink=@runtime.LogSink::memory(),
    )
    let tproxy = g.spawn(() => runtime.serve())
    @async.sleep(400)

    let url = "http://127.0.0.1:18981/"
    // The client declares the body length; the size guard acts on the declared
    // Content-Length before forwarding.
    let small = post_with_cl(url, b"1234")
    assert_eq(small.code, 200)
    // A body over the limit is rejected at the edge.
    let big = post_with_cl(url, b"12345678901234")
    assert_eq(big.code, 413)

    // Only the small request reached the backend; the 413 never did.
    assert_eq(count.length(), 1)
    // The access log carries both statuses.
    let logged = runtime.access_entries()
    assert_eq(logged.length(), 2)
    assert_eq(logged[0].status(), 200)
    assert_eq(logged[1].status(), 413)

    tbackend.cancel()
    tproxy.cancel()
  })
}
