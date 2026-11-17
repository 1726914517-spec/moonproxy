#!/usr/bin/env python3
"""A keep-alive load generator with no third-party dependencies.

It exists so the numbers in README.md can be reproduced on any machine that has
Python 3. It is deliberately small: one blocking connection per worker, no
pipelining, no TLS. That matches how the proxy is exercised in the demo, and it
keeps the measurement honest about what it does and does not include.

Usage:
    python bench/load.py --url http://127.0.0.1:18081/ --concurrency 8 --requests 2000

Start the fixture first:
    moon run cmd/bench --target native
"""

from __future__ import annotations

import argparse
import http.client
import statistics
import sys
import threading
import time
from urllib.parse import urlparse


def percentile(sorted_values: list[float], p: float) -> float:
    """Nearest-rank percentile; no interpolation, so a small sample stays honest."""
    if not sorted_values:
        return 0.0
    k = max(1, int(round(p / 100.0 * len(sorted_values))))
    return sorted_values[min(k, len(sorted_values)) - 1]


def run_phase(host: str, port: int, path: str, concurrency: int, requests: int) -> tuple[list[float], list[str], float]:
    remaining = [requests]
    lock = threading.Lock()
    per_worker: list[list[float]] = [[] for _ in range(concurrency)]
    errors: list[str] = []

    def worker(index: int) -> None:
        conn = http.client.HTTPConnection(host, port, timeout=10)
        while True:
            with lock:
                if remaining[0] <= 0:
                    return
                remaining[0] -= 1
            started = time.perf_counter()
            try:
                conn.request("GET", path)
                response = conn.getresponse()
                response.read()
                if response.status != 200:
                    raise RuntimeError(f"status {response.status}")
            except Exception as exc:  # reconnect once and keep the run going
                errors.append(str(exc))
                try:
                    conn.close()
                except Exception:
                    pass
                conn = http.client.HTTPConnection(host, port, timeout=10)
                continue
            per_worker[index].append((time.perf_counter() - started) * 1000.0)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(concurrency)]
    began = time.perf_counter()
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    elapsed = time.perf_counter() - began
    return [value for batch in per_worker for value in batch], errors, elapsed


def main() -> int:
    parser = argparse.ArgumentParser(description="Keep-alive load generator for moonproxy.")
    parser.add_argument("--url", required=True, help="target URL, e.g. http://127.0.0.1:18081/")
    parser.add_argument("--concurrency", type=int, default=8, help="worker threads (default 8)")
    parser.add_argument("--requests", type=int, default=2000, help="measured requests (default 2000)")
    parser.add_argument("--warmup", type=int, default=200, help="unmeasured requests first (default 200)")
    args = parser.parse_args()

    parsed = urlparse(args.url)
    if parsed.scheme != "http" or not parsed.hostname:
        print("only plain http URLs are supported", file=sys.stderr)
        return 2
    host = parsed.hostname
    port = parsed.port or 80
    path = parsed.path or "/"
    if parsed.query:
        path = f"{path}?{parsed.query}"

    run_phase(host, port, path, args.concurrency, args.warmup)
    samples, errors, elapsed = run_phase(host, port, path, args.concurrency, args.requests)

    if not samples:
        print(f"no successful request; errors={len(errors)}", file=sys.stderr)
        return 1

    ordered = sorted(samples)
    throughput = len(samples) / elapsed if elapsed > 0 else 0.0
    print(f"target        : {args.url}")
    print(f"concurrency   : {args.concurrency}")
    print(f"requests      : {len(samples)} ok, {len(errors)} failed")
    print(f"wall time     : {elapsed:.3f} s")
    print(f"throughput    : {throughput:.0f} req/s")
    print(f"latency (ms)  : p50 {percentile(ordered, 50):.2f}  p90 {percentile(ordered, 90):.2f}  "
          f"p99 {percentile(ordered, 99):.2f}  min {ordered[0]:.2f}  max {ordered[-1]:.2f}  "
          f"mean {statistics.fmean(ordered):.2f}")
    if errors:
        print(f"first error   : {errors[0]}")

    if len(samples) < args.requests:
        print("note: some requests were retried after a connection error", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
