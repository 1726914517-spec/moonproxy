///|
// Blackbox tests for body size governance.

///|
test "content length is read from headers" {
  let headers = [("content-length", "1234")]
  assert_eq(@moonproxy.content_length(headers), Some(1234))
}

///|
test "missing or malformed content length is none" {
  assert_eq(@moonproxy.content_length([]), None)
  assert_eq(@moonproxy.content_length([("content-length", "abc")]), None)
  assert_eq(@moonproxy.content_length([("transfer-encoding", "chunked")]), None)
}

///|
test "body too large compares against the limit" {
  let headers = [("content-length", "5000")]
  assert_eq(@moonproxy.body_too_large(headers, 4096), true)
  assert_eq(@moonproxy.body_too_large(headers, 5000), false) // equal is allowed
  assert_eq(@moonproxy.body_too_large(headers, 6000), false)
}

///|
test "zero limit means unlimited" {
  let headers = [("content-length", "999999999")]
  assert_eq(@moonproxy.body_too_large(headers, 0), false)
}

///|
test "request without declared length is never rejected" {
  assert_eq(
    @moonproxy.body_too_large([("transfer-encoding", "chunked")], 10),
    false,
  )
}

///|
test "conflicting content lengths are rejected" {
  // Two different lengths on one request must not slip past the guard.
  let headers = [("content-length", "4"), ("Content-Length", "14")]
  assert_eq(@moonproxy.body_too_large(headers, 10), true)
  // Repeated but identical values are fine.
  assert_eq(
    @moonproxy.body_too_large(
      [("content-length", "4"), ("content-length", "4")],
      10,
    ),
    false,
  )
}

///|
test "an unparseable content length is rejected when a limit is active" {
  assert_eq(@moonproxy.body_too_large([("content-length", "abc")], 10), true)
  assert_eq(@moonproxy.body_too_large([("content-length", "abc")], 0), false)
}

///|
test "governance defaults to off" {
  let g = @moonproxy.Governance::off()
  assert_true(g.rate_limit() is None)
  assert_eq(g.max_body_bytes(), 0)
}

///|
test "governance carries a rate rule and body limit" {
  let rule = @moonproxy.RateLimitRule::new(capacity=5, refill_per_sec=2)
  let g = @moonproxy.Governance::new(rate_limit=Some(rule), max_body_bytes=1024)
  match g.rate_limit() {
    Some(r) => assert_eq(r.capacity(), 5)
    None => fail("expected a rate rule")
  }
  assert_eq(g.max_body_bytes(), 1024)
}
