///|
// Rate limiting. A token bucket is kept per client key and driven by a clock the
// caller injects (milliseconds), so the logic is fully deterministic and runs
// on every target. The native runtime keys buckets by client IP and answers 429
// when a request is rejected.

///|
/// The bucket rule: a burst of `capacity` tokens, refilled at
/// `refill_per_sec` tokens per second.
pub struct RateLimitRule {
  capacity : Int32
  refill_per_sec : Int32
}

///|
/// Build a rule. Values below 1 are treated as 1 so a rule always permits some
/// forward progress.
pub fn RateLimitRule::new(
  capacity~ : Int32 = 10,
  refill_per_sec~ : Int32 = 1,
) -> RateLimitRule {
  {
    capacity: if capacity < 1 {
      1
    } else {
      capacity
    },
    refill_per_sec: if refill_per_sec < 1 {
      1
    } else {
      refill_per_sec
    },
  }
}

///|
/// The rule's burst capacity.
pub fn RateLimitRule::capacity(self : RateLimitRule) -> Int32 {
  self.capacity
}

///|
/// The rule's refill rate (tokens per second).
pub fn RateLimitRule::refill_per_sec(self : RateLimitRule) -> Int32 {
  self.refill_per_sec
}

///|
/// One key's bucket. `tokens` is the current whole-token balance and `last_ms`
/// the timestamp the balance was last reconciled at; sub-token milliseconds are
/// carried forward so refill is not rounded away.
pub struct TokenBucket {
  mut tokens : Int32
  // Milliseconds since the epoch are ~1.8e12 today, which does not fit in a
  // 32-bit integer, so the clock is kept as Int64 all the way through.
  mut last_ms : Int64
}

///|
/// A set of keyed buckets sharing one rule, plus lifetime counters.
pub struct RateLimiter {
  rule : RateLimitRule
  buckets : Map[String, TokenBucket]
  mut allowed : Int32
  mut rejected : Int32
}

///|
/// Start a limiter with no buckets.
pub fn RateLimiter::new(rule : RateLimitRule) -> RateLimiter {
  { rule, buckets: Map([]), allowed: 0, rejected: 0, }
}

///|
/// Reconcile a bucket with the clock: add the tokens accrued since the last
/// reconciliation (capped at capacity), carrying any unused milliseconds.
fn refill(bucket : TokenBucket, rule : RateLimitRule, now_ms : Int64) -> Unit {
  let elapsed = now_ms - bucket.last_ms
  if elapsed <= 0 {
    return
  }
  // Compute the accrued tokens in Int64: an idle client can leave a gap of many
  // days, and `elapsed * refill_per_sec` overflows a 32-bit integer long before
  // that. Overflowing to a negative value here used to freeze the bucket at zero
  // tokens forever, so the client stayed rejected.
  let added = elapsed * rule.refill_per_sec.to_int64() / 1000
  if added <= 0 {
    return
  }
  if added >= (rule.capacity - bucket.tokens).to_int64() {
    bucket.tokens = rule.capacity
    // Once full, reset the window so a later drain starts fresh from now.
    bucket.last_ms = now_ms
  } else {
    bucket.tokens = bucket.tokens + added.to_int()
    // Advance only by the time the added tokens represent; keep the remainder.
    bucket.last_ms = bucket.last_ms +
      added * 1000 / rule.refill_per_sec.to_int64()
  }
}

///|
/// Decide whether one request for `key` is allowed at `now_ms`. A token is
/// consumed when allowed; otherwise the request is rejected.
pub fn RateLimiter::allow(
  self : RateLimiter,
  key : String,
  now_ms : Int64,
) -> Bool {
  let bucket = match self.buckets.get(key) {
    Some(b) => b
    None => TokenBucket::{ tokens: self.rule.capacity, last_ms: now_ms, }
  }
  refill(bucket, self.rule, now_ms)
  let granted = if bucket.tokens >= 1 {
    bucket.tokens = bucket.tokens - 1
    self.allowed = self.allowed + 1
    true
  } else {
    self.rejected = self.rejected + 1
    false
  }
  self.buckets.set(key, bucket)
  granted
}

///|
/// Total requests allowed since the limiter started.
pub fn RateLimiter::allowed_count(self : RateLimiter) -> Int32 {
  self.allowed
}

///|
/// Total requests rejected since the limiter started.
pub fn RateLimiter::rejected_count(self : RateLimiter) -> Int32 {
  self.rejected
}

///|
/// Current token balance for a key (0 for an unknown key) after refilling to
/// `now_ms`; useful for diagnostics.
pub fn RateLimiter::tokens_for(
  self : RateLimiter,
  key : String,
  now_ms : Int64,
) -> Int32 {
  match self.buckets.get(key) {
    None => 0
    Some(bucket) => {
      refill(bucket, self.rule, now_ms)
      self.buckets.set(key, bucket)
      bucket.tokens
    }
  }
}
