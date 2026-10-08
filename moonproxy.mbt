///|
// moonproxy — a native L7 reverse proxy / load balancer.
//
// This package is the portable decision core. It contains no sockets and no
// native FFI, so it runs on every backend:
//   - `types.mbt`   configuration model (backends, pools, routes, options)
//   - `route.mbt`   host/path matching and specificity ordering
//   - `balance.mbt` five balancing policies
//   - `headers.mbt` hop-by-hop cleanup and forwarding header policy
//   - `health.mbt`  passive health state machine
//   - `retry.mbt`   retry / failover eligibility
//
// The native-only `runtime/` package drives these decisions over real sockets.
