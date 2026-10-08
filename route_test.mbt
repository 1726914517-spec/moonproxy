///|
// Blackbox tests for route matching and specificity.

fn pool() -> @moonproxy.BackendPool {
  @moonproxy.BackendPool::new("p").add(
    @moonproxy.Backend::new("10.0.0.1", 9001),
  )
}

///|
test "normalize host strips port and lowercases" {
  assert_eq(
    @moonproxy.normalize_host("API.Example.com:8080"),
    "api.example.com",
  )
  assert_eq(@moonproxy.normalize_host("api.example.com"), "api.example.com")
}

///|
test "host matching" {
  assert_eq(@moonproxy.host_matches(@moonproxy.Any, "anything"), true)
  assert_eq(@moonproxy.host_matches(@moonproxy.Host("a.com"), "a.com"), true)
  assert_eq(@moonproxy.host_matches(@moonproxy.Host("a.com"), "b.com"), false)
}

///|
test "path matching exact and prefix" {
  assert_eq(@moonproxy.path_matches(@moonproxy.Exact("/a"), "/a"), true)
  assert_eq(@moonproxy.path_matches(@moonproxy.Exact("/a"), "/a/b"), false)
  assert_eq(@moonproxy.path_matches(@moonproxy.Prefix("/a"), "/a"), true)
  assert_eq(@moonproxy.path_matches(@moonproxy.Prefix("/a"), "/a/b"), true)
  assert_eq(@moonproxy.path_matches(@moonproxy.Prefix("/a"), "/b"), false)
}

///|
test "specificity orders host above any and exact above prefix" {
  let exact = @moonproxy.Route::exact("e", "/api", pool())
  let prefix = @moonproxy.Route::prefix("p", "/api", pool())
  let host = @moonproxy.Route::new(
    "h",
    @moonproxy.Host("a.com"),
    @moonproxy.Prefix("/"),
    pool(),
  )
  assert_eq(
    @moonproxy.specificity(exact) > @moonproxy.specificity(prefix),
    true,
  )
  assert_eq(@moonproxy.specificity(host) > @moonproxy.specificity(prefix), true)
}

///|
test "select route returns a match or none" {
  let routes = [
    @moonproxy.Route::prefix("root", "/", pool()),
    @moonproxy.Route::prefix("api", "/api", pool()),
  ]
  assert_eq(
    @moonproxy.select_route(routes, "any.com", "/api/users") is Some(_),
    true,
  )
  assert_eq(
    @moonproxy.select_route(routes, "any.com", "/nope") is Some(_),
    true,
  )
  let only_api = [@moonproxy.Route::prefix("api", "/api", pool())]
  assert_eq(@moonproxy.select_route(only_api, "any.com", "/web") is None, true)
}
