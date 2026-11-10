///|
// Unit tests for structured access logging (native).

fn sample(status : Int32) -> @runtime.AccessLogEntry {
  @runtime.AccessLogEntry::new(
    timestamp_ms=123456789,
    client_ip="127.0.0.1",
    http_method="GET",
    path="/users?id=1",
    status~,
    latency_ms=3,
  )
}

///|
test "access log formats a json line" {
  assert_eq(
    @runtime.format_access_json(sample(200)),
    "{\"timestamp_ms\":123456789,\"client_ip\":\"127.0.0.1\",\"http_method\":\"GET\",\"path\":\"/users?id=1\",\"status\":200,\"latency_ms\":3}",
  )
}

///|
test "json escaping handles quotes and backslashes" {
  let entry = @runtime.AccessLogEntry::new(
    timestamp_ms=1,
    client_ip="1.2.3.4",
    http_method="POST",
    path="/a\"b\\c",
    status=413,
    latency_ms=0,
  )
  let line = @runtime.format_access_json(entry)
  assert_true(line.contains("\"path\":\"/a\\\"b\\\\c\""))
}

///|
test "memory sink captures entries in order" {
  let sink = @runtime.LogSink::memory()
  sink.emit(sample(404))
  sink.emit(sample(200))
  let entries = sink.entries()
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].status(), 404)
  assert_eq(entries[1].status(), 200)
  assert_eq(entries[0].client_ip(), "127.0.0.1")
}
