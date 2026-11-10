///|
// Structured access logging. One record per request is delivered through a
// sink. MoonBit traits are used for generic dispatch rather than runtime
// objects, so the sink is a closed enum: JSON lines on stdout, or an in-memory
// array that tests can inspect.

///|
/// One request's access record.
pub struct AccessLogEntry {
  timestamp_ms : Int64
  client_ip : String
  http_method : String
  path : String
  status : Int32
  latency_ms : Int64
}

///|
/// Build a record.
pub fn AccessLogEntry::new(
  timestamp_ms~ : Int64,
  client_ip~ : String,
  http_method~ : String,
  path~ : String,
  status~ : Int32,
  latency_ms~ : Int64,
) -> AccessLogEntry {
  { timestamp_ms, client_ip, http_method, path, status, latency_ms, }
}

///|
pub fn AccessLogEntry::status(self : AccessLogEntry) -> Int32 {
  self.status
}

///|
pub fn AccessLogEntry::http_method(self : AccessLogEntry) -> String {
  self.http_method
}

///|
pub fn AccessLogEntry::path(self : AccessLogEntry) -> String {
  self.path
}

///|
pub fn AccessLogEntry::client_ip(self : AccessLogEntry) -> String {
  self.client_ip
}

///|
pub fn AccessLogEntry::latency_ms(self : AccessLogEntry) -> Int64 {
  self.latency_ms
}

///|
/// Where completed records go. `Stdout` writes one JSON object per line;
/// `Memory` keeps them in an array for assertions.
pub enum LogSink {
  Stdout
  Memory(Array[AccessLogEntry])
}

///|
/// A sink that keeps records in memory instead of writing them; read them back
/// with `Runtime::access_entries`.
pub fn LogSink::memory() -> LogSink {
  Memory([])
}

///|
/// Deliver one record through the sink.
pub fn LogSink::emit(self : LogSink, entry : AccessLogEntry) -> Unit {
  match self {
    Stdout => println(format_access_json(entry))
    Memory(entries) => entries.push(entry)
  }
}

///|
/// The records captured by a memory sink (empty for the stdout sink).
pub fn LogSink::entries(self : LogSink) -> Array[AccessLogEntry] {
  match self {
    Stdout => []
    Memory(entries) => entries
  }
}

///|
/// Escape a string for safe embedding in a JSON string.
fn json_escape(s : String) -> String {
  let b = StringBuilder()
  let hex : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  for c in s {
    match c {
      '\"' => b.write_string("\\\"")
      '\\' => b.write_string("\\\\")
      '\n' => b.write_string("\\n")
      '\r' => b.write_string("\\r")
      '\t' => b.write_string("\\t")
      _ => {
        let code = c.to_int()
        if code < 0x20 {
          b.write_string("\\u00")
          b.write_char(hex[code / 16])
          b.write_char(hex[code % 16])
        } else {
          b.write_char(c)
        }
      }
    }
  }
  b.to_string()
}

///|
/// Pure JSON formatter for one record (one compact object, no trailing newline).
pub fn format_access_json(entry : AccessLogEntry) -> String {
  let b = StringBuilder()
  b.write_string("{\"timestamp_ms\":")
  b.write_string(entry.timestamp_ms.to_string())
  b.write_string(",\"client_ip\":\"")
  b.write_string(json_escape(entry.client_ip))
  b.write_string("\",\"http_method\":\"")
  b.write_string(json_escape(entry.http_method))
  b.write_string("\",\"path\":\"")
  b.write_string(json_escape(entry.path))
  b.write_string("\",\"status\":")
  b.write_string(entry.status.to_string())
  b.write_string(",\"latency_ms\":")
  b.write_string(entry.latency_ms.to_string())
  b.write_string("}")
  b.to_string()
}
