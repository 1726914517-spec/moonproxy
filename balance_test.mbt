///|
// Blackbox tests for the load-balancing algorithms.

fn three_backends() -> Array[@moonproxy.Backend] {
  [
    @moonproxy.Backend::new("10.0.0.1", 9001),
    @moonproxy.Backend::new("10.0.0.2", 9001),
    @moonproxy.Backend::new("10.0.0.3", 9001),
  ]
}

///|
test "round-robin cycles in order and wraps" {
  let backends = three_backends()
  let bal = @moonproxy.Balancer::new(policy=@moonproxy.RoundRobin)
  assert_eq(@moonproxy.pick(bal, backends), Some(0))
  assert_eq(@moonproxy.pick(bal, backends), Some(1))
  assert_eq(@moonproxy.pick(bal, backends), Some(2))
  assert_eq(@moonproxy.pick(bal, backends), Some(0))
}

///|
test "weighted round-robin shares by weight and interleaves" {
  let backends : Array[@moonproxy.Backend] = [
    @moonproxy.Backend::new("a", 1, weight=5),
    @moonproxy.Backend::new("b", 1, weight=1),
    @moonproxy.Backend::new("c", 1, weight=1),
  ]
  let bal = @moonproxy.Balancer::new(policy=@moonproxy.WeightedRR)
  let counts = [0, 0, 0]
  let mut first_five_all_zero = true
  for turn in 0..<7 {
    let idx = @moonproxy.pick(bal, backends).unwrap()
    counts[idx] = counts[idx] + 1
    if turn < 5 && idx != 0 {
      first_five_all_zero = false
    }
  }
  // Over a full weight cycle each backend is picked exactly its weight.
  assert_eq(counts, [5, 1, 1])
  // Smooth weighting interleaves rather than serving the weight-5 backend five
  // times in a row.
  assert_eq(first_five_all_zero, false)
}

///|
test "least-connections follows in-flight counts" {
  let backends = three_backends()
  let bal = @moonproxy.Balancer::new(policy=@moonproxy.LeastConn)
  assert_eq(@moonproxy.pick(bal, backends), Some(0))
  @moonproxy.acquire(backends, 0)
  assert_eq(@moonproxy.pick(bal, backends), Some(1))
  @moonproxy.acquire(backends, 1)
  assert_eq(@moonproxy.pick(bal, backends), Some(2))
  @moonproxy.release(backends, 0)
  assert_eq(@moonproxy.pick(bal, backends), Some(0))
}

///|
test "random policy uses the injected RNG" {
  let backends = three_backends()
  let bal = @moonproxy.Balancer::new(policy=@moonproxy.Random)
  let idx = Ref(0)
  let seq = [2, 0, 1]
  let rand = fn(_n : Int) -> Int {
    let v = seq[idx.val]
    idx.val = idx.val + 1
    v
  }
  assert_eq(@moonproxy.pick(bal, backends, rand~), Some(2))
  assert_eq(@moonproxy.pick(bal, backends, rand~), Some(0))
  assert_eq(@moonproxy.pick(bal, backends, rand~), Some(1))
}

///|
test "ip-hash pins a key and falls back when no key" {
  let backends = three_backends()
  let bal = @moonproxy.Balancer::new(policy=@moonproxy.IPHash)
  let first = @moonproxy.pick(bal, backends, client_key="203.0.113.7")
  let again = @moonproxy.pick(bal, backends, client_key="203.0.113.7")
  assert_eq(first, again)
  // No key behaves as round-robin rather than hashing the empty string.
  let rr = @moonproxy.Balancer::new(policy=@moonproxy.IPHash)
  assert_eq(@moonproxy.pick(rr, backends), Some(0))
  assert_eq(@moonproxy.pick(rr, backends), Some(1))
}

///|
test "no healthy backend yields None" {
  let backends = three_backends()
  let bal = @moonproxy.Balancer::new(policy=@moonproxy.RoundRobin)
  @moonproxy.mark_down(backends, 0)
  @moonproxy.mark_down(backends, 1)
  @moonproxy.mark_down(backends, 2)
  assert_eq(@moonproxy.pick(bal, backends), None)
}

///|
test "round-robin skips an unhealthy backend" {
  let backends = three_backends()
  let bal = @moonproxy.Balancer::new(policy=@moonproxy.RoundRobin)
  @moonproxy.mark_down(backends, 1)
  assert_eq(@moonproxy.pick(bal, backends), Some(0))
  assert_eq(@moonproxy.pick(bal, backends), Some(2))
  assert_eq(@moonproxy.pick(bal, backends), Some(0))
}
