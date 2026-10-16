///|
// Active health probing — the scheduler half of the active/passive health
// system. Passive health reacts to real traffic (`health.mbt`); active probing
// reaches out to backends that are currently out of rotation so a recovered
// server is brought back even while no traffic would be sent to it.
//
// This file is pure logic and runs on every target: given the current logical
// tick (milliseconds) it decides which backends are due and records a probe
// result through the existing health thresholds. The native runtime owns the
// clock (a sleep loop) and the real dial attempt (`@socket.Tcp::connect`).

///|
/// How often a backend that is down is actively probed.
pub struct ProbePolicy {
  interval_ms : Int
}

///|
/// Build a probe policy; an interval below 1ms is treated as 1ms.
pub fn ProbePolicy::new(interval_ms? : Int = 1000) -> ProbePolicy {
  { interval_ms: if interval_ms < 1 { 1 } else { interval_ms }, }
}

///|
/// The configured probe interval in milliseconds.
pub fn ProbePolicy::interval_ms(self : ProbePolicy) -> Int {
  self.interval_ms
}

///|
/// Indices of backends due for an active probe at tick `now_ms`.
///
/// By default only unhealthy backends are probed (probing healthy ones is
/// redundant with passive health). A backend is due when it has never been
/// probed (`last_probe_ms == 0`) or at least one interval has elapsed.
pub fn due_backends(
  backends : Array[Backend],
  now_ms : Int,
  policy : ProbePolicy,
  only_unhealthy? : Bool = true,
) -> Array[Int] {
  let out : Array[Int] = []
  let mut i = 0
  while i < backends.length() {
    let b = backends[i]
    let eligible = if only_unhealthy { !b.healthy } else { true }
    let elapsed = now_ms - b.last_probe_ms
    let due = b.last_probe_ms == 0 || elapsed >= policy.interval_ms
    if eligible && due {
      out.push(i)
    }
    i = i + 1
  }
  out
}

///|
/// Record the outcome of one active probe at tick `now_ms`. The probe timestamp
/// is stamped regardless of the result, and the outcome is fed through the same
/// thresholds as passive traffic, so recovery still needs a full run of
/// successes (no flap from a single lucky dial).
pub fn record_probe(
  backends : Array[Backend],
  idx : Int,
  ok : Bool,
  health : HealthPolicy,
  now_ms : Int,
) -> Unit {
  let b = backends[idx]
  b.last_probe_ms = now_ms
  backends[idx] = b
  if ok {
    record_success(backends, idx, health)
  } else {
    record_failure(backends, idx, health)
  }
}
