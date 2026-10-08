///|
// moonproxy demo entry point. Running `moon run cmd/main` starts three local
// echo backends and the reverse proxy in one process, so the whole thing can
// be verified with curl on localhost with no external setup.

///|
/// The demo topology:
/// - `web` pool: three backends, smooth weighted round-robin (weights 2/1/1).
/// - `api` pool: one live backend plus one closed port, to show failover.
/// - routes: `/api/*` → api pool; everything else → web pool.
fn demo_config() -> @lib.ProxyConfig {
  let web = @lib.BackendPool::new("web", policy=@lib.WeightedRR)
    .add(@lib.Backend::new("127.0.0.1", 19001, weight=2))
    .add(@lib.Backend::new("127.0.0.1", 19002, weight=1))
    .add(@lib.Backend::new("127.0.0.1", 19003, weight=1))
  let api = @lib.BackendPool::new("api", policy=@lib.RoundRobin)
    .add(@lib.Backend::new("127.0.0.1", 19001))
    .add(@lib.Backend::new("127.0.0.1", 19999)) // nothing listens here
  @lib.ProxyConfig::new(host="127.0.0.1", port=18080)
  .add_route(@lib.Route::prefix("api", "/api", api))
  .add_route(@lib.Route::prefix("root", "/", web))
}

///|
/// A tiny upstream that reports which backend served and the headers the proxy
/// sent, so forwarding is visible in the response body.
async fn echo_backend(port : Int, name : String) -> Unit {
  let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string())
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever(
    (req, _body, conn) => {
      let host = match req.headers.get(@http.CaseInsensitiveString("host")) {
        Some(v) => v
        None => "-"
      }
      let xff = match
        req.headers.get(@http.CaseInsensitiveString("x-forwarded-for")) {
        Some(v) => v
        None => "-"
      }
      let text = "hello from \{name}\nrequest_path: \{req.path}\nreceived_host: \{host}\nx_forwarded_for: \{xff}\n"
      let extra = Map([
        (@http.CaseInsensitiveString("content-type"), "text/plain"),
        (@http.CaseInsensitiveString("x-served-by"), name),
      ])
      conn.send_response(200, "OK", extra_headers=extra)
      conn.write_string(text)
      conn.end_response()
    },
    allow_failure=true,
  )
}

///|
fn print_banner() -> Unit {
  println("moonproxy demo is up")
  println("  proxy   : http://127.0.0.1:18080")
  println("  backends: 127.0.0.1:19001/19002/19003")
  println("try:")
  println("  curl -s http://127.0.0.1:18080/")
  println("  curl -s http://127.0.0.1:18080/api/users")
  println("  curl -s -X POST http://127.0.0.1:18080/ -d 'hello'")
  println("press Ctrl+C to stop")
}

///|
async fn main {
  @async.with_task_group(g => {
    g.spawn_bg(() => echo_backend(19001, "backend-1"))
    g.spawn_bg(() => echo_backend(19002, "backend-2"))
    g.spawn_bg(() => echo_backend(19003, "backend-3"))
    let runtime = @rt.Runtime::new(demo_config())
    g.spawn_bg(() => runtime.serve())
    print_banner()
    while true {
      @async.sleep(60000)
    }
  }) catch {
    _ => ()
  }
}
