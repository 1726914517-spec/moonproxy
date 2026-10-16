///|
// Blackbox tests for the active-probe scheduler.

test "a never-probed unhealthy backend is due immediately" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  @moonproxy.mark_down(backends, 0)
  let policy = @moonproxy.ProbePolicy::new(interval_ms=1000)
  assert_eq(@moonproxy.due_backends(backends, 0, policy), [0])
}

///|
test "healthy backends are not probed by default" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  let policy = @moonproxy.ProbePolicy::new(interval_ms=1000)
  assert_eq(@moonproxy.due_backends(backends, 0, policy), [])
}

///|
test "a backend is not due again until the interval elapses" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  @moonproxy.mark_down(backends, 0)
  let health = @moonproxy.HealthPolicy::new(
    unhealthy_threshold=1,
    healthy_threshold=1,
  )
  let policy = @moonproxy.ProbePolicy::new(interval_ms=1000)
  @moonproxy.record_probe(backends, 0, false, health, 1000)
  // 500ms later: not due yet
  assert_eq(@moonproxy.due_backends(backends, 1500, policy), [])
  // 1000ms later: due again
  assert_eq(@moonproxy.due_backends(backends, 2000, policy), [0])
}

///|
test "healthy backends are probed when only_unhealthy is false" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  let policy = @moonproxy.ProbePolicy::new(interval_ms=1000)
  assert_eq(
    @moonproxy.due_backends(backends, 0, policy, only_unhealthy=false),
    [0],
  )
}

///|
test "a successful probe revives a backend at the recovery threshold" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  let health = @moonproxy.HealthPolicy::new(
    unhealthy_threshold=1,
    healthy_threshold=2,
  )
  @moonproxy.mark_down(backends, 0)
  @moonproxy.record_probe(backends, 0, true, health, 1000)
  assert_eq(backends[0].is_healthy(), false) // one probe not enough
  @moonproxy.record_probe(backends, 0, true, health, 2000)
  assert_eq(backends[0].is_healthy(), true)
  assert_eq(backends[0].last_probe_ms(), 2000)
}

///|
test "a failed probe keeps a down backend down and stamps the time" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  let health = @moonproxy.HealthPolicy::new(
    unhealthy_threshold=1,
    healthy_threshold=1,
  )
  @moonproxy.mark_down(backends, 0)
  @moonproxy.record_probe(backends, 0, false, health, 1000)
  assert_eq(backends[0].is_healthy(), false)
  assert_eq(backends[0].last_probe_ms(), 1000)
}

///|
test "interval below one is clamped to one" {
  let policy = @moonproxy.ProbePolicy::new(interval_ms=0)
  assert_eq(policy.interval_ms(), 1)
}
