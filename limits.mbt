///|
// Request body size governance. A pure decision based on the declared
// Content-Length lets the native runtime reject an oversized request before it
// streams the body (HTTP 413). A chunked request without a Content-Length
// cannot be sized up front and is not preemptively rejected here.

///|
/// The declared body size in bytes, or `None` when there is no parseable
/// Content-Length (e.g. a chunked request or a malformed value).
pub fn content_length(headers : Array[(String, String)]) -> UInt64? {
  for (k, v) in headers {
    if k.to_lower() == "content-length" {
      let len = @string.parse_uint64(v, base=10) catch { _ => return None }
      return Some(len)
    }
  }
  None
}

///|
/// Whether a request exceeds the configured maximum body size. A limit of 0
/// means unlimited; a request without a declared length is never rejected here.
pub fn body_too_large(
  headers : Array[(String, String)],
  max_bytes : UInt64,
) -> Bool {
  if max_bytes == 0 {
    return false
  }
  match content_length(headers) {
    Some(len) => len > max_bytes
    None => false
  }
}
