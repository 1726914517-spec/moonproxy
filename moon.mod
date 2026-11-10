// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "1726914517-spec/moonproxy"

version = "0.3.1"

readme = "README.mbt.md"

repository = "https://github.com/1726914517-spec/moonproxy"

license = "Apache-2.0"

keywords = [
  "http",
  "reverse-proxy",
  "load-balancer",
  "network",
  "server",
  "rate-limiting",
  "observability",
]

preferred_target = "wasm"

description = "A native L7 reverse proxy / load balancer runtime with edge governance: host/path routing, five balancing policies, header policy, health checks and failover, plus per-client rate limiting, body size limits and structured access logs."

import {
  "moonbitlang/async@0.22.4",
}
