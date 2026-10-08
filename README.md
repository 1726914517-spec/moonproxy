# moonproxy

A native L7 **reverse proxy / load balancer runtime** for [MoonBit] — the
category of nginx, HAProxy and Traefik. It terminates client HTTP/1.1
connections, matches each request to a route, picks a backend through a pool's
balancer, and forwards both directions while cleaning connection-level headers
and failing over when a backend is down.

The forwarding decision logic (routing, balancing, header policy, health and
retry) lives in a portable core that compiles to `wasm`, `wasm-gc`, `js` and
`native`; the socket runtime that actually moves bytes is native-only.

## Features

- **Host and path routing** — named hosts beat the wildcard host; exact paths
  beat prefixes; longer prefixes beat shorter ones.
- **Five load-balancing policies** — round-robin, smooth weighted round-robin,
  least connections, random (with an injectable RNG) and client-IP hash
  (FNV-1a for stable affinity).
- **Connection-safe header forwarding** — strips hop-by-hop and per-connection
  headers, then adds `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`
  and `X-Real-IP`, and rewrites `Host` to the upstream.
- **Passive health tracking** — consecutive failures trip a backend and
  consecutive successes bring it back; tripped backends are skipped.
- **Failover and retry** — a connection failure retries another backend for any
  method (nothing was sent); a `5xx` is retried elsewhere only for idempotent
  methods; a failure after the request body started is never replayed.
- **Streaming** — request and response bodies are piped through readers, so
  responses are not buffered wholesale.

## Ecosystem position

There is no running reverse proxy on mooncakes today. The nearby packages sit
at other layers, and moonproxy does not overlap them:

- `LuoYunxin1/moonnginx` parses an nginx directive tree; it does not start a
  server or forward requests.
- `moonbitstack/mooncat`, `mocket`, `moonback` and the other HTTP servers are
  *application* servers (ASGI / uvicorn-style); they serve an app and only
  rewrite trusted proxy headers, they do not proxy to upstreams.
- `moonhttp` is HTTP encoding/decoding with no sockets.
- `moonzero` is a Go-zero-style microservice framework whose balancer serves
  its own internal RPC client, not an edge proxy.

## Quickstart

Prerequisite: the MoonBit toolchain (`moon`). The native runtime needs a C
toolchain on the machine — MSVC (`cl.exe`) on Windows, clang/gcc on Linux and
macOS.

Run the bundled demo. It starts three echo backends and the proxy in one
process — no external setup:

```bash
moon run cmd/main --target native
```

Then, from another shell:

```bash
# weighted round-robin across the three backends
curl -s http://127.0.0.1:18080/

# routed to the api pool
curl -s http://127.0.0.1:18080/api/users

# a request body is forwarded
curl -s -X POST http://127.0.0.1:18080/ -d 'hello'
```

The `/api` pool deliberately includes a closed port; requests still succeed
because the proxy fails over to the live backend.

## Configuration as code

There is no config file parser in v0.1 — a proxy is built with the core API:

```moonbit
let web = BackendPool::new("web", policy=WeightedRR)
  .add(Backend::new("10.0.0.1", 8080, weight=2))
  .add(Backend::new("10.0.0.2", 8080, weight=1))
let config = ProxyConfig::new(host="0.0.0.0", port=80)
  .add_route(Route::prefix("root", "/", web))
let runtime = @runtime.Runtime::new(config)
runtime.serve()
```

## Build and test

```bash
moon fmt
moon check --target all --deny-warn
moon build --target all
moon test  --target all
```

The portable core has 25 black-box tests that run on all four targets; the
native runtime additionally has an end-to-end test that brings up real
backends and a real proxy over localhost.

## Engineering boundaries (v0.1)

Being explicit about what this release does not do:

- The `Host` sent upstream is the dialed upstream address — the nginx default
  (`$proxy_host`). The original host is carried in `X-Forwarded-Host`.
- Health is passive (driven by real connection/response outcomes); a periodic
  active probe is not included yet.
- The edge speaks HTTP/1.1; HTTP/2 and TLS termination are not in this release.
- The decision core is portable, but the socket runtime is native-only, since
  it relies on async's native socket FFI.

## License

Apache-2.0

[MoonBit]: https://www.moonbitlang.com/
