///|
// Health accounting. Each backend carries a consecutive-failure count and a
// health bit; the functions here are the only place those fields change, so the
// policy lives in one testable spot. Functions take the pool's backend array
// and an index (MoonBit arrays have interior mutability) rather than a mutable
// receiver. Active probing schedules real dial attempts in the native runtime
// and reports through `record_success` / `record_failure`.

///|
/// The thresholds that move a backend between healthy and unhealthy. A backend
/// goes unhealthy after `unhealthy_threshold` consecutive failures and returns
/// healthy only after `healthy_threshold` consecutive successes while it was
/// down — a single lucky probe should not flap a server back into rotation.
pub struct HealthPolicy {
  unhealthy_threshold : Int
  healthy_threshold : Int
}

///|
/// Build a policy; thresholds below 1 are treated as 1.
pub fn HealthPolicy::new(
  unhealthy_threshold? : Int = 2,
  healthy_threshold? : Int = 2,
) -> HealthPolicy {
  {
    unhealthy_threshold: if unhealthy_threshold < 1 {
      1
    } else {
      unhealthy_threshold
    },
    healthy_threshold: if healthy_threshold < 1 {
      1
    } else {
      healthy_threshold
    },
  }
}

///|
/// Count one successful exchange: clear the failure streak and, if the backend
/// was being held out, require a full run of successes before re-enabling it.
pub fn record_success(
  backends : Array[Backend],
  idx : Int,
  policy : HealthPolicy,
) -> Unit {
  let b = backends[idx]
  if b.healthy {
    b.failures = 0
  } else {
    b.failures = b.failures + 1
    if b.failures >= policy.healthy_threshold {
      b.healthy = true
      b.failures = 0
    }
  }
  backends[idx] = b
}

///|
/// Count one failed exchange: reset progress toward recovery and, once the
/// failure streak reaches the threshold, pull the backend out of rotation.
pub fn record_failure(
  backends : Array[Backend],
  idx : Int,
  policy : HealthPolicy,
) -> Unit {
  let b = backends[idx]
  if b.healthy {
    b.failures = b.failures + 1
    if b.failures >= policy.unhealthy_threshold {
      b.healthy = false
      b.failures = 0
    }
  } else {
    b.failures = 0
  }
  backends[idx] = b
}

///|
/// Mark a backend directly down (used when a connection cannot even be
/// established — an unambiguous failure worth a hard removal).
pub fn mark_down(backends : Array[Backend], idx : Int) -> Unit {
  let b = backends[idx]
  b.healthy = false
  b.failures = 0
  backends[idx] = b
}

///|
/// Mark a backend directly up after a successful active probe.
pub fn mark_up(backends : Array[Backend], idx : Int) -> Unit {
  let b = backends[idx]
  b.healthy = true
  b.failures = 0
  backends[idx] = b
}

///|
/// Whether this backend may receive traffic.
pub fn Backend::is_healthy(self : Backend) -> Bool {
  self.healthy
}

///|
/// Record that a request has started using backend `idx`, for least-connections
/// balancing.
pub fn acquire(backends : Array[Backend], idx : Int) -> Unit {
  let b = backends[idx]
  b.active_conns = b.active_conns + 1
  backends[idx] = b
}

///|
/// Record that a request has finished using backend `idx`; the count never goes
/// negative.
pub fn release(backends : Array[Backend], idx : Int) -> Unit {
  let b = backends[idx]
  if b.active_conns > 0 {
    b.active_conns = b.active_conns - 1
  }
  backends[idx] = b
}

///|
/// The indices of every healthy backend, in array order. Returning indices
/// (rather than copies) lets the runtime select and then mutate the entry.
pub fn healthy_indices(backends : Array[Backend]) -> Array[Int] {
  let out : Array[Int] = []
  let mut i = 0
  while i < backends.length() {
    if backends[i].healthy {
      out.push(i)
    }
    i = i + 1
  }
  out
}
