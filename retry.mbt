///|
// Retry and failover decisions. The native runtime, when a chosen backend
// cannot be reached or answers with a retryable status, may move to another
// healthy backend. The rules here keep that safe: a connection that never
// established delivered nothing, so trying another backend is safe for any
// method; an upstream status means the request may already have had an effect,
// so only idempotent methods may be retried.

///|
/// Whether a method is idempotent by definition (RFC 9110 §9.2.1): repeating
/// it leaves the server in the same state. `PUT` is idempotent; `POST` and
/// `PATCH` are not.
pub fn is_idempotent(meth : String) -> Bool {
  ["GET", "HEAD", "OPTIONS", "TRACE", "PUT"].contains(meth.to_upper())
}

///|
/// Whether an upstream status is worth retrying on another backend: any 5xx
/// server error. Other statuses are the backend's deliberate answer and are
/// passed through.
pub fn is_retryable_status(status : Int) -> Bool {
  status >= 500 && status <= 599
}

///|
/// Whether a request that saw `status` from an upstream may be retried on a
/// peer: a retryable status from an idempotent method.
pub fn can_retry_status(meth : String, status : Int) -> Bool {
  is_retryable_status(status) && is_idempotent(meth)
}
