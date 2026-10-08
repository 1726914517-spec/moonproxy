///|
// Route matching. A request is matched on its normalized Host and path; among
// all matching routes the most specific one wins (a named host beats any host,
// an exact path beats a prefix, a longer prefix beats a shorter one). This is
// decided by specificity rather than array order so adding a broad catch-all
// route never shadows a precise rule listed later.

///|
/// Strip the port a Host header often carries (`example.com:8080`) and
/// lowercase it, so host matching compares names only and is case-insensitive.
pub fn normalize_host(host : String) -> String {
  let h = match host.find(":") {
    Some(colon) => host[0:colon].to_owned()
    None => host
  }
  h.to_lower()
}

///|
/// Whether a host matcher accepts the (already normalized, lowercase) host.
pub fn host_matches(matcher : HostMatch, host : String) -> Bool {
  match matcher {
    Any => true
    Host(name) => name.to_lower() == host
  }
}

///|
/// Whether a path matcher accepts the request path. `Exact` compares the whole
/// path; `Prefix` tests a literal prefix (nginx semantics), which matches the
/// prefix itself and everything beneath it.
pub fn path_matches(matcher : PathMatch, path : String) -> Bool {
  match matcher {
    Exact(want) => want == path
    Prefix(prefix) => path.has_prefix(prefix)
  }
}

///|
/// Whether a route matches this host and path.
pub fn route_matches(route : Route, host : String, path : String) -> Bool {
  host_matches(route.host, host) && path_matches(route.path, path)
}

///|
/// A route's specificity score; higher wins. Named hosts outrank any host, and
/// within the same host exact paths outrank prefixes, with longer prefixes more
/// specific than shorter ones.
pub fn specificity(route : Route) -> Int {
  let host_score = match route.host {
    Any => 0
    Host(_) => 1_000_000
  }
  let path_score = match route.path {
    Exact(want) => 100_000 + want.length()
    Prefix(prefix) => prefix.length()
  }
  host_score + path_score
}

///|
/// Select the most specific route matching `host` and `path`, or `None` when no
/// route matches (the runtime answers 404 in that case). The host argument is
/// normalized before comparison.
pub fn select_route(
  routes : Array[Route],
  host : String,
  path : String,
) -> Route? {
  let h = normalize_host(host)
  let mut best : Route? = None
  let mut best_score = -1
  for route in routes {
    if route_matches(route, h, path) {
      let score = specificity(route)
      if score > best_score {
        best_score = score
        best = Some(route)
      }
    }
  }
  best
}
