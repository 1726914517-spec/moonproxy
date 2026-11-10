///|
// Blackbox tests for the token-bucket rate limiter.

fn rule3() -> @moonproxy.RateLimitRule {
  @moonproxy.RateLimitRule::new(capacity=3, refill_per_sec=10)
}

///|
test "burst fills capacity then rejects" {
  let limiter = @moonproxy.RateLimiter::new(rule3())
  assert_eq(limiter.allow("c", 0), true)
  assert_eq(limiter.allow("c", 0), true)
  assert_eq(limiter.allow("c", 0), true)
  assert_eq(limiter.allow("c", 0), false)
  assert_eq(limiter.allowed_count(), 3)
  assert_eq(limiter.rejected_count(), 1)
}

///|
test "refill adds tokens over time" {
  let limiter = @moonproxy.RateLimiter::new(rule3())
  for _ in 0..<3 {
    assert_eq(limiter.allow("c", 0), true)
  }
  assert_eq(limiter.allow("c", 0), false)
  // 100 ms at 10 tokens/sec adds exactly one token.
  assert_eq(limiter.allow("c", 100), true)
  assert_eq(limiter.allow("c", 100), false)
  // Another 100 ms adds one more.
  assert_eq(limiter.allow("c", 200), true)
  assert_eq(limiter.allow("c", 200), false)
}

///|
test "sub-token milliseconds carry forward" {
  let limiter = @moonproxy.RateLimiter::new(rule3())
  for _ in 0..<3 {
    ignore(limiter.allow("c", 0))
  }
  // 50 ms is not enough for a whole token; nothing is granted yet.
  assert_eq(limiter.allow("c", 50), false)
  // The elapsed time is retained, so at 100 ms one token is available.
  assert_eq(limiter.allow("c", 100), true)
}

///|
test "refill never exceeds capacity" {
  let limiter = @moonproxy.RateLimiter::new(rule3())
  for _ in 0..<3 {
    ignore(limiter.allow("c", 0))
  }
  // After a long wait the balance is capped, not accumulated without bound.
  assert_eq(limiter.tokens_for("c", 100000), 3)
  assert_eq(limiter.allow("c", 100000), true)
  assert_eq(limiter.tokens_for("c", 100000), 2)
}

///|
test "keys are limited independently" {
  let limiter = @moonproxy.RateLimiter::new(rule3())
  for _ in 0..<3 {
    ignore(limiter.allow("a", 0))
  }
  assert_eq(limiter.allow("a", 0), false)
  // A different key still has its full burst.
  assert_eq(limiter.allow("b", 0), true)
  assert_eq(limiter.tokens_for("b", 0), 2)
}

///|
test "rule values below one are normalized" {
  let rule = @moonproxy.RateLimitRule::new(capacity=0, refill_per_sec=0)
  assert_eq(rule.capacity(), 1)
  assert_eq(rule.refill_per_sec(), 1)
}
