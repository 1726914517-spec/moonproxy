///|
// Header processing, kept as pure functions over `(name, value)` pairs with
// lowercase names. Two jobs: strip hop-by-hop and framing headers (RFC 7230
// §6.1) so the async layer can reframe, and add the de-facto forwarding
// headers a backend needs to know the real client. The native runtime converts
// its case-insensitive header map to this shape and back.

///|
/// Hop-by-hop headers (RFC 7230 §6.1.1) plus the framing headers the async
/// client/server manage themselves. These must never be proxied verbatim.
fn is_hop_by_hop(name : String) -> Bool {
  [
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
    "trailer", "transfer-encoding", "upgrade", "content-length",
  ].contains(name)
}

///|
/// Look up a header by (lowercase) name; last value wins.
fn header_get(headers : Array[(String, String)], name : String) -> String? {
  let mut found : String? = None
  for (k, v) in headers {
    if k.to_lower() == name {
      found = Some(v)
    }
  }
  found
}

///|
/// Set a header, replacing every existing occurrence with one value, or
/// appending when absent.
fn header_set(
  headers : Array[(String, String)],
  name : String,
  value : String,
) -> Unit {
  let kept : Array[(String, String)] = []
  let mut replaced = false
  for (k, v) in headers {
    if k.to_lower() == name {
      if !replaced {
        kept.push((name, value))
        replaced = true
      }
    } else {
      kept.push((k, v))
    }
  }
  if !replaced {
    kept.push((name, value))
  }
  headers.clear()
  for item in kept {
    headers.push(item)
  }
}

///|
/// Remove every occurrence of a header.
fn header_remove(headers : Array[(String, String)], name : String) -> Unit {
  let kept : Array[(String, String)] = []
  for (k, v) in headers {
    if k.to_lower() != name {
      kept.push((k, v))
    }
  }
  headers.clear()
  for item in kept {
    headers.push(item)
  }
}

///|
/// The set of header names to strip from a request: the hop-by-hop set plus any
/// headers the sender's `Connection` header lists as connection-specific.
fn request_removal(incoming : Array[(String, String)]) -> Array[String] {
  let remove : Array[String] = []
  for (k, _v) in incoming {
    let name = k.to_lower()
    if is_hop_by_hop(name) {
      remove.push(name)
    }
  }
  match header_get(incoming, "connection") {
    Some(raw) =>
      for part in raw.split(",") {
        let name = part.trim().to_lower().to_owned()
        if name.length() > 0 {
          remove.push(name)
        }
      }
    None => ()
  }
  remove
}

///|
/// Build the request headers to send upstream.
///
/// Removes hop-by-hop / connection-specific headers; rewrites `Host` to the
/// upstream address unless `preserve_host`; and, when forwarding headers is
/// enabled, appends the peer to any existing `X-Forwarded-For` chain and fills
/// `X-Forwarded-Proto`, `X-Forwarded-Host` and `X-Real-IP`. Existing values
/// are preserved (a correctly-configured earlier hop is trusted).
pub fn forward_request_headers(
  incoming : Array[(String, String)],
  client_ip : String,
  scheme : String,
  original_host : String,
  upstream_host : String,
  options : RouteOptions,
) -> Array[(String, String)] {
  let remove = request_removal(incoming)
  let out : Array[(String, String)] = []
  for (k, v) in incoming {
    let name = k.to_lower()
    if !remove.contains(name) {
      out.push((name, v))
    }
  }
  // Host: preserve the original or rewrite to the backend.
  header_remove(out, "host")
  let host = if options.preserve_host { original_host } else { upstream_host }
  out.push(("host", host))
  if options.forward_headers {
    // X-Forwarded-For appends this hop's peer to the chain.
    let xff = match header_get(out, "x-forwarded-for") {
      Some(prev) => prev + ", " + client_ip
      None => client_ip
    }
    header_set(out, "x-forwarded-for", xff)
    if header_get(out, "x-forwarded-proto") is None {
      header_set(out, "x-forwarded-proto", scheme)
    }
    if header_get(out, "x-forwarded-host") is None {
      header_set(out, "x-forwarded-host", original_host)
    }
    if header_get(out, "x-real-ip") is None {
      header_set(out, "x-real-ip", client_ip)
    }
  }
  out
}

///|
/// Filter an upstream response's headers for the client: drop hop-by-hop and
/// framing headers (the server connection re-establishes framing) and pass
/// everything else through unchanged.
pub fn forward_response_headers(
  upstream : Array[(String, String)],
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for (k, v) in upstream {
    let name = k.to_lower()
    if !is_hop_by_hop(name) {
      out.push((name, v))
    }
  }
  out
}
