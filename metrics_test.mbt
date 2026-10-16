///|
// Blackbox tests for traffic metrics.

test "counters count dispatched, successful and failed requests" {
  let backends = [@moonproxy.Backend::new("a", 1)]
  @moonproxy.count_request(backends, 0)
  @moonproxy.count_request(backends, 0)
  @moonproxy.count_success(backends, 0)
  @moonproxy.count_failure(backends, 0)
  let stats = @moonproxy.snapshot(backends)
  assert_eq(stats.length(), 1)
  assert_eq(stats[0].address(), "a:1")
  assert_eq(stats[0].total_requests(), 2)
  assert_eq(stats[0].success_count(), 1)
  assert_eq(stats[0].fail_count(), 1)
}

///|
test "snapshot preserves array order and health" {
  let backends = [
    @moonproxy.Backend::new("a", 1),
    @moonproxy.Backend::new("b", 2),
  ]
  @moonproxy.mark_down(backends, 1)
  let stats = @moonproxy.snapshot(backends)
  assert_eq(stats[0].address(), "a:1")
  assert_eq(stats[0].is_healthy(), true)
  assert_eq(stats[1].address(), "b:2")
  assert_eq(stats[1].is_healthy(), false)
}
