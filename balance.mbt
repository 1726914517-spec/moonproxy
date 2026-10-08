///|
// Load balancing. A `Balancer` holds the small amount of state repeated picks
// need (a round-robin cursor and the smooth-weighted-roller's per-backend
// credits) and chooses one healthy backend index. Randomness is injected for
// the `Random` policy, so every algorithm is deterministic under test. The
// native runtime keeps one Balancer per pool and calls `pick` per request.

///|
/// Per-pool balancer state.
pub struct Balancer {
  policy : LBPolicy
  mut cursor : Int
  mut current : Array[Int]
}

///|
/// Build a balancer for the given policy.
pub fn Balancer::new(policy? : LBPolicy = RoundRobin) -> Balancer {
  { policy, cursor: 0, current: [], }
}

///|
/// FNV-1a (32-bit) over a key's codepoints — a stable, dependency-free hash
/// used to pin a client to a backend. Keys here are IP addresses (ASCII), so
/// codepoint hashing and byte hashing agree. The offset basis exceeds the
/// signed Int range, so it is built as a UInt by reinterpreting its negative
/// two's-complement pattern.
fn fnv1a(key : String) -> UInt {
  let mut h = (-2128831035).reinterpret_as_uint() // FNV offset basis 2166136261
  let prime = (16777619).reinterpret_as_uint()
  for c in key {
    h = h ^ c.to_int().reinterpret_as_uint()
    h = h * prime
  }
  h
}

///|
/// Make sure the weighted-roller credit array matches the backend count,
/// resetting it when the pool resized so stale credits never leak.
fn ensure_current(balancer : Balancer, n : Int) -> Unit {
  if balancer.current.length() != n {
    let zeros : Array[Int] = []
    let mut i = 0
    while i < n {
      zeros.push(0)
      i = i + 1
    }
    balancer.current = zeros
  }
}

///|
/// Round-robin pick over the healthy subset.
fn pick_round_robin(balancer : Balancer, healthy : Array[Int]) -> Int {
  let n = healthy.length()
  let choice = healthy[balancer.cursor % n]
  balancer.cursor = balancer.cursor + 1
  choice
}

///|
/// Smooth weighted round-robin (nginx algorithm): each pass credits every
/// healthy backend its weight, picks the highest, then charges it the total —
/// spreading a weight-5 backend through the cycle instead of five in a row.
fn pick_weighted(
  balancer : Balancer,
  backends : Array[Backend],
  healthy : Array[Int],
) -> Int {
  ensure_current(balancer, backends.length())
  let mut total = 0
  for i in healthy {
    balancer.current[i] = balancer.current[i] + backends[i].weight
    total = total + backends[i].weight
  }
  let mut best = healthy[0]
  for i in healthy {
    if balancer.current[i] > balancer.current[best] {
      best = i
    }
  }
  balancer.current[best] = balancer.current[best] - total
  best
}

///|
/// Least-connections pick: the healthy backend with the fewest in-flight
/// requests; ties resolve to the first such backend.
fn pick_least_conn(backends : Array[Backend], healthy : Array[Int]) -> Int {
  let mut best = healthy[0]
  for i in healthy {
    if backends[i].active_conns < backends[best].active_conns {
      best = i
    }
  }
  best
}

///|
/// Choose a healthy backend index, or `None` when nothing is healthy (the
/// runtime then fails over or answers 502).
///
/// `client_key` feeds IPHash; `rand`, given `(n)` and returning a value in
/// `[0,n)`, feeds Random. If a policy's input is missing the choice falls back
/// to round-robin rather than failing.
pub fn pick(
  balancer : Balancer,
  backends : Array[Backend],
  client_key? : String = "",
  rand? : (Int) -> Int,
  exclude? : Array[Int] = [],
) -> Int? {
  let all_healthy = healthy_indices(backends)
  let healthy : Array[Int] = []
  for idx in all_healthy {
    if !exclude.contains(idx) {
      healthy.push(idx)
    }
  }
  if healthy.length() == 0 {
    return None
  }
  match balancer.policy {
    RoundRobin => Some(pick_round_robin(balancer, healthy))
    WeightedRR => Some(pick_weighted(balancer, backends, healthy))
    LeastConn => Some(pick_least_conn(backends, healthy))
    Random =>
      match rand {
        Some(r) => Some(healthy[r(healthy.length())])
        None => Some(pick_round_robin(balancer, healthy))
      }
    IPHash =>
      if client_key.length() == 0 {
        Some(pick_round_robin(balancer, healthy))
      } else {
        let n = healthy.length().reinterpret_as_uint()
        let slot = (fnv1a(client_key) % n).reinterpret_as_int()
        Some(healthy[slot])
      }
  }
}
