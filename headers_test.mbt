///|
// Blackbox tests for request/response header processing.

fn get(headers : Array[(String, String)], name : String) -> String? {
  let mut found : String? = None
  for (k, v) in headers {
    if k == name {
      found = Some(v)
    }
  }
  found
}

///|
test "request: strips hop-by-hop and connection-enumerated headers" {
  let incoming = [
    ("host", "api.example.com"),
    ("connection", "keep-alive, x-custom"),
    ("keep-alive", "timeout=5"),
    ("x-custom", "drop-me"),
    ("accept", "application/json"),
    ("content-length", "10"),
  ]
  let out = @moonproxy.forward_request_headers(
    incoming,
    "203.0.113.9",
    "http",
    "api.example.com",
    "10.0.0.5:9001",
    @moonproxy.RouteOptions::defaults(),
  )
  assert_eq(get(out, "connection"), None)
  assert_eq(get(out, "keep-alive"), None)
  assert_eq(get(out, "x-custom"), None)
  assert_eq(get(out, "content-length"), None)
  assert_eq(get(out, "accept"), Some("application/json"))
}

///|
test "request: rewrites host and builds forwarding headers" {
  let incoming = [("host", "api.example.com"), ("x-forwarded-for", "10.0.0.1")]
  let out = @moonproxy.forward_request_headers(
    incoming,
    "203.0.113.9",
    "http",
    "api.example.com",
    "10.0.0.5:9001",
    @moonproxy.RouteOptions::defaults(),
  )
  assert_eq(get(out, "host"), Some("10.0.0.5:9001"))
  assert_eq(get(out, "x-forwarded-for"), Some("10.0.0.1, 203.0.113.9"))
  assert_eq(get(out, "x-forwarded-proto"), Some("http"))
  assert_eq(get(out, "x-forwarded-host"), Some("api.example.com"))
  assert_eq(get(out, "x-real-ip"), Some("203.0.113.9"))
}

///|
test "request: preserve-host keeps the original host" {
  let incoming = [("host", "api.example.com")]
  let out = @moonproxy.forward_request_headers(
    incoming,
    "203.0.113.9",
    "http",
    "api.example.com",
    "10.0.0.5:9001",
    @moonproxy.RouteOptions::new(preserve_host=true),
  )
  assert_eq(get(out, "host"), Some("api.example.com"))
}

///|
test "request: disabling forward headers omits them" {
  let incoming = [("host", "api.example.com")]
  let out = @moonproxy.forward_request_headers(
    incoming,
    "203.0.113.9",
    "http",
    "api.example.com",
    "10.0.0.5:9001",
    @moonproxy.RouteOptions::new(forward_headers=false),
  )
  assert_eq(get(out, "x-forwarded-for"), None)
  assert_eq(get(out, "x-real-ip"), None)
}

///|
test "response: strips framing but passes content through" {
  let upstream = [
    ("content-length", "42"),
    ("connection", "close"),
    ("content-type", "text/plain"),
    ("set-cookie", "sid=abc"),
  ]
  let out = @moonproxy.forward_response_headers(upstream)
  assert_eq(get(out, "content-length"), None)
  assert_eq(get(out, "connection"), None)
  assert_eq(get(out, "content-type"), Some("text/plain"))
  assert_eq(get(out, "set-cookie"), Some("sid=abc"))
}
