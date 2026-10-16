///|
// Native active-probe loop. This is the clock/dial half of the active health
// system: it wakes every interval, asks the portable core which backends are
// due, attempts a real TCP connect to each, and feeds the outcome back through
// the shared health thresholds. Pure scheduling stays in the core so it is
// tested on every target; only the dial and the sleep loop live here.

///|
/// Whether a TCP connection to `host:port` can be established. A refused or
/// unreachable backend raises from `connect`, which is reported as `false`.
async fn tcp_reachable(address : String) -> Bool {
  let addr = @socket.Addr::parse(address) catch { _ => return false }
  let conn = @socket.Tcp::connect(addr) catch { _ => return false }
  conn.close()
  true
}

///|
/// Periodically probe every unique pool's backends until the process stops.
/// Spawn it once beside `serve` in a task group. The logical clock starts at
/// zero and advances by exactly one interval per wake, so the scheduler's
/// timing is deterministic and independent of the wall clock.
pub async fn Runtime::run_probes(
  self : Runtime,
  interval_ms? : Int = 1000,
) -> Unit {
  let policy = @moonproxy.ProbePolicy::new(interval_ms~)
  let health = self.health
  let mut now = 0
  while true {
    @async.sleep(interval_ms)
    now = now + interval_ms
    // A pool can be referenced by more than one route; probe each pool once.
    let seen : Map[String, Unit] = Map([])
    let routes = self.config.routes()
    for route in routes {
      let pool = route.pool()
      let id = pool.id()
      if !seen.contains(id) {
        seen.set(id, ())
        let backends = pool.backends()
        let due = @moonproxy.due_backends(backends, now, policy)
        for idx in due {
          let address = backends[idx].address()
          let ok = tcp_reachable(address)
          @moonproxy.record_probe(backends, idx, ok, health, now)
        }
      }
    }
  }
}
