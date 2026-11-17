# Changelog

All notable changes to this module are recorded here. Versions follow
[Semantic Versioning](https://semver.org/); every version listed below is
published on [mooncakes](https://mooncakes.io/docs/1726914517-spec/moonproxy).

## 0.4.3 — 2026-11-17

### Fixed

- The 0.1.0 entry claimed `Set-Cookie` passthrough, but multiple cookies were
  in fact dropped until 0.2.2; the entry now lists only what 0.1.0 did.
- CI widened its burst to 20 requests (6 on `/api`), so a slow runner still
  crosses the limit while tokens refill, and its fallback cleanup matches the
  binary path instead of every command line containing `cmd/main`.

### Changed

- README states that multi-value `Set-Cookie` is forwarded intact, and that
  route ids must be unique because they key the per-route limiter.

## 0.4.2 — 2026-11-17

### Added

- `cmd/bench`: a benchmark fixture — two echo backends behind a proxy with no
  governance rules and a memory log sink, so a load generator measures
  forwarding cost rather than the rate limiter or logging.
- `bench/load.py`: a keep-alive load generator with no third-party
  dependencies, so the numbers can be reproduced without installing anything.
- CI now asserts the governance path end to end on every push: a burst that
  ends in `429`, both bucket sets (proxy-wide and per-route), an oversized body
  answering `413`, and a `"route_id"` in the access log.

### Changed

- README opens with a CI badge and its quickstart names the status code each
  command should produce.
- The repository carries this changelog from this release on.

## 0.4.1 — 2026-11-17

### Fixed

- The quickstart's 429 demo used a shell loop. Every iteration started a new
  `curl`, and the gap between processes was long enough for the bucket to
  refill, so a reader following the README saw twelve `200`s and concluded the
  limit was not implemented. The demo now fires the burst from one `curl`
  process.

### Changed

- `moon.mod` description mentions per-route quotas alongside per-client ones.

## 0.4.0 — 2026-11-17

### Added

- `Route::with_rate_limit`: a route can declare its own token-bucket rule. Its
  buckets are keyed per route id, so a strict quota on one route cannot drain
  another route's quota; routes without a rule inherit the proxy-wide policy.
- `RateLimiter::prune`: drops buckets that are full and have been idle for a
  minute. A full idle bucket behaves exactly like one that never existed, so
  this costs no correctness. Partly drained buckets are deliberately kept —
  dropping them would hand the client a fresh burst.
- `AccessLogEntry::route_id`: every access record names the route that served
  the request, or `-` when nothing matched. The JSON line carries `route_id`
  right after `path`.

### Changed

- The idle-bucket sweep is triggered from the request path (at most once every
  30 s) instead of a background task, so `serve` is a plain `run_forever` with
  nothing to tear down.

## 0.3.1 — 2026-11-10

### Fixed

- `TokenBucket.last_ms` was an `Int32` holding epoch milliseconds. After a few
  days of idling, `elapsed * refill_per_sec` overflowed into a negative number,
  the refill branch returned early without advancing `last_ms`, and that client
  IP was rejected forever. It is an `Int64` now, with a regression test that
  simulates ten idle days.

## 0.3.0 — 2026-11-10

### Added

- Per-client token-bucket rate limiting: burst capacity plus a steady refill,
  `429 Too Many Requests` with `Retry-After` before any backend is touched.
- Request body size limit: an oversized declared `Content-Length` is rejected
  with `413 Payload Too Large` at the edge.
- Structured access logs: one JSON record per request (timestamp, client,
  method, path, status, latency) written to an injectable sink — JSON lines on
  stdout by default, or an in-memory sink for tests and embedding.

## 0.2.2 — 2026-11-10

### Fixed

- A request whose body had already been streamed was retried on another
  backend after a `5xx`, replaying an empty body. Retry now requires that
  nothing was sent.
- Multiple `Set-Cookie` headers were dropped on the way back to the client. They
  now travel through the dedicated cookie channel.
- An exact path route missed requests carrying a query string and answered
  `404`. Route matching uses the path only; the full target is still forwarded.

## 0.2.1 — 2026-11-03

### Changed

- Migrated to `Int32` and labeled-argument syntax for the current toolchain;
  regenerated the published interface.

## 0.2.0 — 2026-10-16

### Added

- Active health probes: a loop dials backends that are out of rotation every
  interval, so a recovered server is re-added without waiting for traffic.
- Per-backend metrics: total requests, successes and failures, exposed through
  a snapshot alongside live health and connection state.

## 0.1.1 — 2026-10-08

### Fixed

- CI: refresh the module registry before building, and surface check/build/test
  output as workflow annotations.

### Changed

- Filled in `repository`, `description` and `keywords` metadata.

## 0.1.0 — 2026-10-08

### Added

- Host and path routing with specificity ordering (named host over wildcard,
  exact over prefix, longer prefix over shorter).
- Five balancing policies: round-robin, smooth weighted round-robin, least
  connections, random with an injectable RNG, and client-IP hash.
- Hop-by-hop header cleanup, `X-Forwarded-*` injection and upstream `Host`
  rewrite.
- Passive health tracking and method-aware failover/retry.
- Native socket runtime with streaming request and response bodies.
- Single-process demo (`cmd/main`) and CI covering all four targets plus a
  localhost smoke test.
