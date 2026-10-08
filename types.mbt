///|
// moonproxy core domain model. Everything here is pure MoonBit that compiles
// on every target (wasm, js, native); the socket runtime lives in the
// native-only `runtime` package and drives these types.

///|
/// The scheme used to reach an upstream backend. Only cleartext HTTP is
/// implemented in this version; `Https` is accepted in the model so a config
/// can name it, and reported as unsupported at the edge rather than dropped.
pub(all) enum Scheme {
  Http
  Https
}

///|
/// The default port a scheme implies when a backend names none.
pub fn Scheme::default_port(self : Scheme) -> Int {
  match self {
    Http => 80
    Https => 443
  }
}

///|
/// One upstream server instance a pool may forward to. Health and the live
/// connection count mutate as the proxy runs, so those fields are mutable;
/// identity and weight are fixed configuration.
pub struct Backend {
  host : String
  port : Int
  weight : Int
  scheme : Scheme
  mut healthy : Bool
  mut failures : Int
  mut active_conns : Int
}

///|
/// Build a backend from an explicit address. `weight` defaults to 1 and a
/// weight below 1 is treated as 1 so a misconfiguration can never zero out a
/// pool's share. A backend starts healthy and assumed reachable.
pub fn Backend::new(
  host : String,
  port : Int,
  weight? : Int = 1,
  scheme? : Scheme = Http,
) -> Backend {
  let w = if weight < 1 { 1 } else { weight }
  {
    host,
    port,
    weight: w,
    scheme,
    healthy: true,
    failures: 0,
    active_conns: 0,
  }
}

///|
/// The `host:port` text used to key and display this backend.
pub fn Backend::address(self : Backend) -> String {
  self.host + ":" + self.port.to_string()
}

///|
/// The origin URL (`scheme://host:port`) the native client dials.
pub fn Backend::origin(self : Backend) -> String {
  let scheme = match self.scheme {
    Http => "http://"
    Https => "https://"
  }
  scheme + self.host + ":" + self.port.to_string()
}

///|
/// The backend's host (IP or resolvable name).
pub fn Backend::host(self : Backend) -> String {
  self.host
}

///|
/// The backend's port.
pub fn Backend::port(self : Backend) -> Int {
  self.port
}

///|
/// How a route matches a request's path. `Exact` is the whole request target's
/// path component; `Prefix` matches any path beneath it.
pub(all) enum PathMatch {
  Exact(String)
  Prefix(String)
}

///|
/// How a route matches a request's Host header. `Any` matches every host;
/// `Host` is a case-insensitive exact name.
pub(all) enum HostMatch {
  Any
  Host(String)
}

///|
/// The load-balancing policy a pool uses to choose among its healthy backends.
pub(all) enum LBPolicy {
  /// Cycle through backends in order, spreading requests evenly.
  RoundRobin
  /// Smooth weighted round-robin (← nginx `weight`): interleave picks in
  /// proportion to each backend's weight.
  WeightedRR
  /// Send to the backend with the fewest in-flight requests.
  LeastConn
  /// Pick uniformly at random (RNG injected, so it is testable).
  Random
  /// Pin a client key (its IP) to a backend by a stable hash.
  IPHash
}

///|
/// A named group of interchangeable backends and the policy that balances over
/// them. A route points at one pool.
pub struct BackendPool {
  id : String
  backends : Array[Backend]
  policy : LBPolicy
}

///|
/// Start an empty pool with the given id and policy.
pub fn BackendPool::new(
  id : String,
  policy? : LBPolicy = RoundRobin,
) -> BackendPool {
  { id, backends: [], policy, }
}

///|
/// Add a backend and return the pool, so construction chains
/// (`BackendPool::new("api").add(a).add(b)`).
pub fn BackendPool::add(self : BackendPool, backend : Backend) -> BackendPool {
  let pool = self
  pool.backends.push(backend)
  pool
}

///|
/// The pool's id.
pub fn BackendPool::id(self : BackendPool) -> String {
  self.id
}

///|
/// The pool's backends (the live array the runtime balances over).
pub fn BackendPool::backends(self : BackendPool) -> Array[Backend] {
  self.backends
}

///|
/// The pool's load-balancing policy.
pub fn BackendPool::policy(self : BackendPool) -> LBPolicy {
  self.policy
}

///|
/// Per-route forwarding knobs. Defaults follow what nginx does.
pub struct RouteOptions {
  /// Forward the incoming Host instead of rewriting it to the backend's.
  preserve_host : Bool
  /// Add `X-Forwarded-For / Proto / Host` and `X-Real-IP`.
  forward_headers : Bool
  /// Retry the next backend on a connect failure or idempotent 5xx.
  failover : Bool
}

///|
/// The mainstream defaults: rewrite Host to the upstream, emit forwarding
/// headers, and fail over to a healthy peer.
pub fn RouteOptions::defaults() -> RouteOptions {
  { preserve_host: false, forward_headers: true, failover: true, }
}

///|
/// Build options with explicit toggles; any omitted field takes the default.
pub fn RouteOptions::new(
  preserve_host? : Bool = false,
  forward_headers? : Bool = true,
  failover? : Bool = true,
) -> RouteOptions {
  { preserve_host, forward_headers, failover, }
}

///|
/// A routing rule: when host and path match, forward to `pool`.
pub struct Route {
  id : String
  host : HostMatch
  path : PathMatch
  pool : BackendPool
  options : RouteOptions
}

///|
/// Build a route with an explicit host and path matcher.
pub fn Route::new(
  id : String,
  host : HostMatch,
  path : PathMatch,
  pool : BackendPool,
  options? : RouteOptions = RouteOptions::defaults(),
) -> Route {
  { id, host, path, pool, options, }
}

///|
/// A route that matches any host and forwards a path prefix to `pool`.
pub fn Route::prefix(id : String, prefix : String, pool : BackendPool) -> Route {
  Route::new(id, Any, Prefix(prefix), pool)
}

///|
/// A route that matches any host and forwards an exact path to `pool`.
pub fn Route::exact(id : String, path : String, pool : BackendPool) -> Route {
  Route::new(id, Any, Exact(path), pool)
}

///|
/// The pool this route forwards to.
pub fn Route::pool(self : Route) -> BackendPool {
  self.pool
}

///|
/// This route's forwarding options.
pub fn Route::options(self : Route) -> RouteOptions {
  self.options
}

///|
/// The top-level proxy configuration: where to listen and the ordered route
/// table. Routes are matched by specificity, not array order.
pub struct ProxyConfig {
  listen_host : String
  listen_port : Int
  routes : Array[Route]
}

///|
/// Start a config bound to `host:port`; add routes with `add_route`.
pub fn ProxyConfig::new(
  host? : String = "127.0.0.1",
  port? : Int = 8080,
) -> ProxyConfig {
  { listen_host: host, listen_port: port, routes: [], }
}

///|
/// Append a route and return the config for chaining.
pub fn ProxyConfig::add_route(self : ProxyConfig, route : Route) -> ProxyConfig {
  let config = self
  config.routes.push(route)
  config
}

///|
/// The `host:port` text the listener binds.
pub fn ProxyConfig::bind(self : ProxyConfig) -> String {
  self.listen_host + ":" + self.listen_port.to_string()
}

///|
/// The host the listener binds.
pub fn ProxyConfig::listen_host(self : ProxyConfig) -> String {
  self.listen_host
}

///|
/// The port the listener binds.
pub fn ProxyConfig::listen_port(self : ProxyConfig) -> Int {
  self.listen_port
}

///|
/// The route table.
pub fn ProxyConfig::routes(self : ProxyConfig) -> Array[Route] {
  self.routes
}
