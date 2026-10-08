///|
// Blackbox tests for retry/failover decisions.

test "idempotent methods" {
  assert_eq(@moonproxy.is_idempotent("GET"), true)
  assert_eq(@moonproxy.is_idempotent("get"), true)
  assert_eq(@moonproxy.is_idempotent("HEAD"), true)
  assert_eq(@moonproxy.is_idempotent("PUT"), true)
  assert_eq(@moonproxy.is_idempotent("OPTIONS"), true)
  assert_eq(@moonproxy.is_idempotent("POST"), false)
  assert_eq(@moonproxy.is_idempotent("PATCH"), false)
}

///|
test "retryable statuses are 5xx only" {
  assert_eq(@moonproxy.is_retryable_status(500), true)
  assert_eq(@moonproxy.is_retryable_status(502), true)
  assert_eq(@moonproxy.is_retryable_status(503), true)
  assert_eq(@moonproxy.is_retryable_status(504), true)
  assert_eq(@moonproxy.is_retryable_status(404), false)
  assert_eq(@moonproxy.is_retryable_status(429), false)
  assert_eq(@moonproxy.is_retryable_status(200), false)
}

///|
test "can retry requires idempotent method and retryable status" {
  assert_eq(@moonproxy.can_retry_status("GET", 500), true)
  assert_eq(@moonproxy.can_retry_status("POST", 500), false)
  assert_eq(@moonproxy.can_retry_status("GET", 404), false)
  assert_eq(@moonproxy.can_retry_status("POST", 503), false)
}
