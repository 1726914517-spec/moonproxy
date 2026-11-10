# moonproxy

A native L7 **reverse proxy / load balancer runtime** for [MoonBit] — the
category of nginx, HAProxy and Traefik. It terminates client HTTP/1.1
connections, matches each request to a route, picks a backend through a pool's
balancer, and forwards both directions while cleaning connection-level headers
and failing over when a backend is down. On top of forwarding it applies edge
governance — per-client rate limiting, request body size limits and structured
access logging — so traffic is protected and observable before it reaches
upstream.

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
- **Active and passive health tracking** — passive health trips a backend after
  consecutive real failures and restores it after a run of successes; an active
  probe loop additionally dials backends that are out of rotation every interval
  so a recovered server is brought back without waiting for traffic.
- **Per-backend metrics** — total requests, successes and failures are counted
  per backend and exposed through a snapshot, alongside live health and
  connection state.
- **Failover and retry** — a connection failure retries another backend for any
  method (nothing was sent); a `5xx` is retried elsewhere only for idempotent
  methods; a failure after the request body started is never replayed.
- **Streaming** — request and response bodies are piped through readers, so
  responses are not buffered wholesale.
- **Per-client rate limiting** — a token bucket per client IP (burst capacity
  plus a steady refill) rejects excess requests with `429 Too Many Requests`
  and a `Retry-After` header before any backend is touched.
- **Request body size limit** — an oversized declared `Content-Length` is
  rejected with `413 Payload Too Large` at the edge, so the bytes never travel
  upstream.
- **Structured access logs** — one JSON record per request (timestamp, client,
  method, path, status, latency) goes to an injectable sink: JSON lines on
  stdout by default, or an in-memory sink for tests and embedding.

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

# push past the burst capacity (5) to see the edge answer 429
for i in $(seq 1 8); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:18080/; done

# a body over the 1 KiB cap is rejected with 413 before reaching the backend
python -c "open('big.file','wb').write(b'x'*2048)"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:18080/ --data-binary @big.file
```

Every request also prints one JSON access line on the demo's stdout.

The `/api` pool deliberately includes a closed port; requests still succeed
because the proxy fails over to the live backend. The demo also spawns an active
probe loop every second, so a backend that comes back online is automatically
re-added to rotation.

## Configuration as code

There is no config file parser yet — a proxy is built with the core API:

```moonbit nocheck
let web = BackendPool::new("web", policy=WeightedRR)
  .add(Backend::new("10.0.0.1", 8080, weight=2))
  .add(Backend::new("10.0.0.2", 8080, weight=1))
// Edge governance: a burst of 20 requests refilling at 10/s, bodies capped at 1 MiB.
let rule = RateLimitRule::new(capacity=20, refill_per_sec=10)
let governance = Governance::new(rate_limit=Some(rule), max_body_bytes=1048576)
let config = ProxyConfig::new(host="0.0.0.0", port=80, governance)
  .add_route(Route::prefix("root", "/", web))
// Default sink writes JSON lines; pass LogSink::memory() to capture records.
let runtime = @runtime.Runtime::new(config)
g.spawn_bg(() => runtime.run_probes(interval_ms=1000)) // active health
runtime.serve()
```

With the memory sink, the records are available in-process instead of being
printed:

```moonbit nocheck
let runtime = @runtime.Runtime::new(config, sink=LogSink::memory())
// ... after requests ...
for entry in runtime.access_entries() {
  // entry.http_method(), entry.path(), entry.status(), entry.latency_ms(), ...
}
```

## Build and test

```bash
moon fmt
moon check --target all --deny-warn
moon build --target all
moon test  --target all
```

The portable core has 49 black-box tests that run on all four targets; the
native runtime additionally has seven end-to-end tests that bring up real
backends and a real proxy over localhost. They cover weighted balancing and
failover, active-probe recovery of a backend that comes back online, the
retry/cookie/query semantics, and the governance path: a burst that earns
`429` (then refills), an oversized body rejected with `413` before it reaches
the backend, and the access records captured through the memory sink.

## Engineering boundaries

Being explicit about what this release does not do:

- The `Host` sent upstream is the dialed upstream address — the nginx default
  (`$proxy_host`). The original host is carried in `X-Forwarded-Host`.
- The active probe is a TCP-connect check on a fixed interval; it does not yet
  send an HTTP health path or honor custom probe timeouts.
- The edge speaks HTTP/1.1; HTTP/2 and TLS termination are not in this
  release. The async HTTP layer exposes no server-side TLS in its public API,
  so HTTPS termination cannot be built without reimplementing HTTP framing.
- Rate limiting is global and keyed by client IP across all routes; per-route
  rules are not configurable yet.
- Rate-limit buckets are kept per client IP and are never evicted, so a very
  large number of distinct source addresses grows the map without bound. A
  production edge would add an LRU or an idle-expiry sweep; this release does
  not.
- The body size guard acts on the declared `Content-Length`. A chunked request
  without a length cannot be sized up front and is not preemptively rejected.
- The decision core is portable, but the socket runtime (including the probe
  dial loop and the access log sinks) is native-only, since it relies on
  async's native socket FFI.

## License

Apache-2.0

[MoonBit]: https://www.moonbitlang.com/
