///|
// Per-backend traffic metrics. The counters are the single source of truth for
// how many requests were dispatched, succeeded and failed, so an operator can
// see the balancer's view of a pool. Like the health functions these are pure
// and compile on every target; the native runtime calls them around each
// forward attempt, and `snapshot` makes them observable in tests and logs.

///|
/// An immutable point-in-time view of one backend's counters.
pub struct BackendStats {
  address : String
  healthy : Bool
  weight : Int
  active_conns : Int
  total_requests : Int
  success_count : Int
  fail_count : Int
}

///|
/// Count one request dispatched to backend `idx`.
pub fn count_request(backends : Array[Backend], idx : Int) -> Unit {
  let b = backends[idx]
  b.total_requests = b.total_requests + 1
  backends[idx] = b
}

///|
/// Count one successful exchange with backend `idx`.
pub fn count_success(backends : Array[Backend], idx : Int) -> Unit {
  let b = backends[idx]
  b.success_count = b.success_count + 1
  backends[idx] = b
}

///|
/// Count one failed exchange with backend `idx`.
pub fn count_failure(backends : Array[Backend], idx : Int) -> Unit {
  let b = backends[idx]
  b.fail_count = b.fail_count + 1
  backends[idx] = b
}

///|
/// Snapshot every backend's counters in array order.
pub fn snapshot(backends : Array[Backend]) -> Array[BackendStats] {
  let out : Array[BackendStats] = []
  for b in backends {
    out.push({
      address: b.address(),
      healthy: b.healthy,
      weight: b.weight,
      active_conns: b.active_conns,
      total_requests: b.total_requests,
      success_count: b.success_count,
      fail_count: b.fail_count,
    })
  }
  out
}

///|
/// The stats entry's `address:port`.
pub fn BackendStats::address(self : BackendStats) -> String {
  self.address
}

///|
/// Whether the backend was healthy at the snapshot.
pub fn BackendStats::is_healthy(self : BackendStats) -> Bool {
  self.healthy
}

///|
/// Requests dispatched at the snapshot.
pub fn BackendStats::total_requests(self : BackendStats) -> Int {
  self.total_requests
}

///|
/// Successful exchanges at the snapshot.
pub fn BackendStats::success_count(self : BackendStats) -> Int {
  self.success_count
}

///|
/// Failed exchanges at the snapshot.
pub fn BackendStats::fail_count(self : BackendStats) -> Int {
  self.fail_count
}

///|
/// In-flight requests at the snapshot.
pub fn BackendStats::active_conns(self : BackendStats) -> Int {
  self.active_conns
}
