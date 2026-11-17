///|
/// Benchmark fixture: two echo backends behind a proxy that applies **no**
/// governance, so a load generator measures forwarding cost instead of the
/// rate limiter. Ports are deliberately distinct from the demo's so both can
/// run side by side.
fn bench_config() -> @lib.ProxyConfig {
  let web = @lib.BackendPool::new("web")
    .add(@lib.Backend::new("127.0.0.1", 19011))
    .add(@lib.Backend::new("127.0.0.1", 19012))
  @lib.ProxyConfig::new(host="127.0.0.1", port=18081).add_route(
    @lib.Route::prefix("root", "/", web),
  )
}

///|
async fn echo_backend(port : Int32, name : String) -> Unit {
  let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string())
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever(
    (_req, _body, conn) => {
      let text = "hello from \{name}\n"
      let extra = Map([(@http.CaseInsensitiveString("x-served-by"), name)])
      conn.send_response(200, "OK", extra_headers=extra)
      conn.write_string(text)
      conn.end_response()
    },
    allow_failure=true,
  )
}

///|
async fn main {
  @async.with_task_group(g => {
    g.spawn_bg(() => echo_backend(19011, "bench-1"))
    g.spawn_bg(() => echo_backend(19012, "bench-2"))
    // Memory sink: the point of this fixture is forwarding cost, so the access
    // log must not pay for a write per request. The demo keeps the stdout sink.
    let runtime = @rt.Runtime::new(bench_config(), sink=@rt.LogSink::memory())
    g.spawn_bg(() => runtime.serve())
    println("moonproxy bench fixture is up")
    println(
      "  proxy      : http://127.0.0.1:18081  (no rate limit, no body cap)",
    )
    println("  backends   : 127.0.0.1:19011, 127.0.0.1:19012")
    println("  try        : python bench/load.py --url http://127.0.0.1:18081/")
    while true {
      @async.sleep(60000)
    }
  }) catch {
    _ => ()
  }
}
