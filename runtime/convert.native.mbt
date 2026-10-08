///|
// Native-only conversions between the async HTTP header map and the plain
// `(String, String)` pairs the portable core works with.

///|
/// Flatten a case-insensitive header map into lowercase-name/value pairs.
fn headers_to_pairs(
  headers : Map[@http.CaseInsensitiveString, String],
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for (k, v) in headers.to_array() {
    out.push((k.to_string(), v))
  }
  out
}

///|
/// Build a case-insensitive header map from plain name/value pairs (the async
/// HTTP client/server take a `Map`, not an array of pairs).
fn to_ci_map(
  pairs : Array[(String, String)],
) -> Map[@http.CaseInsensitiveString, String] {
  let entries : Array[(@http.CaseInsensitiveString, String)] = []
  for (k, v) in pairs {
    entries.push((@http.CaseInsensitiveString(k), v))
  }
  Map(entries)
}

///|
/// Look up a header by lowercase name without constructing a case-insensitive
/// key. Returns the first value.
fn header_value(
  headers : Map[@http.CaseInsensitiveString, String],
  name : String,
) -> String? {
  let mut found : String? = None
  for (k, v) in headers.to_array() {
    if k.to_string().to_lower() == name {
      found = Some(v)
    }
  }
  found
}

///|
/// Extract just the IP text from a peer `Addr` (whose display form is
/// `ip:port`, or `[v6]:port`).
fn ip_of(addr : @socket.Addr) -> String {
  let s = addr.to_string()
  if s.has_prefix("[") {
    let b = StringBuilder()
    let mut started = false
    for c in s {
      if c == '[' {
        started = true
      } else if c == ']' {
        break
      } else if started {
        b.write_char(c)
      }
    }
    b.to_string()
  } else {
    let mut ip = s
    for part in s.split(":") {
      ip = part.to_owned()
      break
    }
    ip
  }
}

///|
/// Map the async request-method enum to its wire spelling.
fn method_to_string(meth : @http.RequestMethod) -> String {
  match meth {
    @http.Get => "GET"
    @http.Head => "HEAD"
    @http.Post => "POST"
    @http.Put => "PUT"
    @http.Delete => "DELETE"
    @http.Connect => "CONNECT"
    @http.Options => "OPTIONS"
    @http.Trace => "TRACE"
    @http.Patch => "PATCH"
  }
}
