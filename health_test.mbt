///|
// Blackbox tests for health accounting.

test "failures reach threshold before going down" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  let policy = @moonproxy.HealthPolicy::new(unhealthy_threshold=2)
  assert_eq(backends[0].is_healthy(), true)
  @moonproxy.record_failure(backends, 0, policy)
  assert_eq(backends[0].is_healthy(), true) // one failure still in rotation
  @moonproxy.record_failure(backends, 0, policy)
  assert_eq(backends[0].is_healthy(), false)
}

///|
test "recovery needs a full run of successes (no flap)" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  let policy = @moonproxy.HealthPolicy::new(
    unhealthy_threshold=1,
    healthy_threshold=2,
  )
  @moonproxy.mark_down(backends, 0)
  @moonproxy.record_success(backends, 0, policy)
  assert_eq(backends[0].is_healthy(), false) // one probe is not enough
  @moonproxy.record_success(backends, 0, policy)
  assert_eq(backends[0].is_healthy(), true)
}

///|
test "a failure while recovering resets progress" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  let policy = @moonproxy.HealthPolicy::new(
    unhealthy_threshold=1,
    healthy_threshold=2,
  )
  @moonproxy.mark_down(backends, 0)
  @moonproxy.record_success(backends, 0, policy)
  @moonproxy.record_failure(backends, 0, policy)
  @moonproxy.record_success(backends, 0, policy)
  assert_eq(backends[0].is_healthy(), false) // streak broken, still down
}

///|
test "mark up and healthy indices" {
  let backends = [
    @moonproxy.Backend::new("a", 1),
    @moonproxy.Backend::new("b", 1),
    @moonproxy.Backend::new("c", 1),
  ]
  @moonproxy.mark_down(backends, 1)
  assert_eq(@moonproxy.healthy_indices(backends), [0, 2])
  @moonproxy.mark_up(backends, 1)
  assert_eq(@moonproxy.healthy_indices(backends), [0, 1, 2])
}

///|
test "release never drives the connection count below zero" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  @moonproxy.release(backends, 0)
  @moonproxy.acquire(backends, 0)
  @moonproxy.release(backends, 0)
  @moonproxy.release(backends, 0)
  // No panic and the pool still lists the backend as healthy.
  assert_eq(@moonproxy.healthy_indices(backends), [0])
}
