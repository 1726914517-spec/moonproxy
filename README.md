# moonproxy

[![CI](https://github.com/1726914517-spec/moonproxy/actions/workflows/ci.yml/badge.svg)](https://github.com/1726914517-spec/moonproxy/actions/workflows/ci.yml)

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
  and `X-Real-IP`, and rewrites `Host` to the upstream. Multi-value `Set-Cookie`
  is forwarded intact: the HTTP parser keeps it out of the header map, so it
  travels back on its own channel instead of being collapsed.
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
- **Per-client rate limiting, per route when needed** — a token bucket keyed by
  client IP rejects excess requests with `429 Too Many Requests` and a
  `Retry-After` header before any backend is touched. A route can declare its
  own rule with `Route::with_rate_limit`; its buckets are keyed per route, so a
  strict quota on one route never eats into the quota of another, and routes
  without a rule inherit the proxy-wide policy. Route ids must be unique — they
  key those buckets and appear in every access record.
- **Request body size limit** — an oversized declared `Content-Length` is
  rejected with `413 Payload Too Large` at the edge, so the bytes never travel
  upstream.
- **Structured access logs** — one JSON record per request (timestamp, client,
  method, path, matched route id, status, latency) goes to an injectable sink:
  JSON lines on stdout by default, or an in-memory sink for tests and embedding.

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

Then, from another shell. Each line names the status code it should produce;
the governance cases are asserted by CI on every push, so a green badge above
means this path really works:

```bash
# weighted round-robin across the three backends -> 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/

# routed to the api pool -> 200 (one member is a closed port; failover answers)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/api/users

# a request body is forwarded -> 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:18080/ -d 'hello'

# fire the burst from ONE curl process: 10 x 200, then 2 x 429. A shell loop
# would start a new curl per request, and the gap between processes is long
# enough for the bucket to refill, so the limit would look absent.
curl -s $(printf -- '-o /dev/null http://127.0.0.1:18080/ %.0s' {1..12}) -w '%{http_code} '

# the /api route owns a smaller burst (2), independent of the rule above -> 200 200 429 429
curl -s $(printf -- '-o /dev/null http://127.0.0.1:18080/api/users %.0s' {1..4}) -w '%{http_code} '

# a body over the 1 KiB cap is rejected before reaching any backend -> 413
python -c "open('big.file','wb').write(b'x'*2048)"
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:18080/ --data-binary @big.file
```

Every request also prints one JSON access line on the demo's stdout — including
`"route_id"`, so a rejection or a 404 still tells you which route was matched.

The `/api` pool deliberately includes a closed port; requests still succeed
because the proxy fails over to the live backend. The demo also spawns an active
probe loop every second, so a backend that comes back online is automatically
re-added to rotation.

## Configuration as code

There is no config file parser yet — a proxy is built with the core API:

```moonbit
let web = BackendPool::new("web", policy=WeightedRR)
  .add(Backend::new("10.0.0.1", 8080, weight=2))
  .add(Backend::new("10.0.0.2", 8080, weight=1))
// Edge governance: a burst of 20 requests refilling at 10/s, bodies capped at 1 MiB.
let rule = RateLimitRule::new(capacity=20, refill_per_sec=10)
let governance = Governance::new(rate_limit=Some(rule), max_body_bytes=1048576)
// A route may override the proxy-wide rule; its buckets stay its own.
let api = BackendPool::new("api").add(Backend::new("10.0.0.3", 8080))
let api_rule = RateLimitRule::new(capacity=5, refill_per_sec=2)
let config = ProxyConfig::new(host="0.0.0.0", port=80, governance)
  .add_route(Route::prefix("api", "/api", api).with_rate_limit(api_rule))
  .add_route(Route::prefix("root", "/", web))
// Default sink writes JSON lines; pass LogSink::memory() to capture records.
let runtime = @runtime.Runtime::new(config)
g.spawn_bg(() => runtime.run_probes(interval_ms=1000)) // active health
runtime.serve()
```

With the memory sink, the records are available in-process instead of being
printed:

```moonbit
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

The portable core has 56 black-box tests that run on all four targets; the
native runtime adds 13 tests, nine of which are end-to-end runs that bring up
real backends and a real proxy over localhost. They cover weighted balancing and
failover, active-probe recovery of a backend that comes back online, the
retry/cookie/query semantics, and the governance path: a burst that earns
`429` (then refills), a route whose quota is isolated from its neighbours, an
oversized body rejected with `413` before it reaches the backend, and the access
records — including the route id that served each request — captured through the
memory sink.

## Load testing

Two pieces ship with the repo so a reader can measure forwarding cost instead
of taking a number on faith:

- `cmd/bench` starts two echo backends and a proxy on ports 18081 / 19011 /
  19012 with **no** governance rules, so the rate limiter does not shape the
  sample. It writes to the memory log sink, so access logging does not dominate
  the measurement either.
- `bench/load.py` is a keep-alive load generator with no third-party
  dependencies: one blocking connection per worker, no pipelining, no TLS.

```bash
moon run cmd/bench --target native          # fixture
python bench/load.py --url http://127.0.0.1:19011/ --concurrency 8 --requests 3000
python bench/load.py --url http://127.0.0.1:18081/ --concurrency 8 --requests 3000
```

The first run talks to a backend directly, the second goes through the proxy,
so the difference between them is the forwarding cost on that machine. Both
backends and the proxy run in one process and share one async event loop,
everything is loopback and unencrypted — this is a cost probe, not a capacity
claim. Laptop measurements swing with background load, so measure on the
hardware you care about rather than quoting someone else's run.

## Engineering boundaries

Being explicit about what this release does not do:

- The `Host` sent upstream is the dialed upstream address — the nginx default
  (`$proxy_host`). The original host is carried in `X-Forwarded-Host`.
- The active probe is a TCP-connect check on a fixed interval; it does not yet
  send an HTTP health path or honor custom probe timeouts.
- The edge speaks HTTP/1.1; HTTP/2 and TLS termination are not in this
  release. The async HTTP layer exposes no server-side TLS in its public API,
  so HTTPS termination cannot be built without reimplementing HTTP framing.
- Rate-limit state is per client IP and per route id. A sweep runs at most once
  every 30 s, piggybacked on the request path, and drops buckets that are full
  and have been idle for a minute — a full idle bucket behaves exactly like one
  that never existed, so this costs no correctness. Partly drained buckets are
  deliberately kept (dropping them would hand the client a fresh burst), so a
  flood of distinct source addresses that each spend one token can still grow
  the table. There is no hard cap or LRU bound yet.
- The body size guard acts on the declared `Content-Length`. A chunked request
  without a length cannot be sized up front and is not preemptively rejected.
- The decision core is portable, but the socket runtime (including the probe
  dial loop and the access log sinks) is native-only, since it relies on
  async's native socket FFI.

## License

Apache-2.0

[MoonBit]: https://www.moonbitlang.com/
