import Config

config :logger, level: :warning

config :wardrik, WardrikBrave,
  api_key: "test-brave-api-key",
  base_url: "https://brave.test",
  req_options: [plug: {Req.Test, WardrikBrave.Stub}, retry: false]

config :wardrik, WardrikNotify, req_options: [plug: {Req.Test, WardrikNotify.Stub}]

# A connection that retries, or waits out a burst of tool changes, does so in
# milliseconds rather than a second or a quarter of one.
config :wardrik, WardrikMCP, first_retry: 10, refresh_after: 10

# The fleet writes to a real store, so the suite gets one of its own, unique
# per run so two suites can run side by side. test_helper.exs removes it.
config :wardrik, Wardrik.Store,
  adapter: Wardrik.Store.EKV,
  data_dir:
    Path.join([
      System.tmp_dir!(),
      "wardrik-test",
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    ])

# OAuth hosts resolve without DNS, and a device flow polls as often as the
# test's stub server asks.
config :wardrik, WardrikOAuth, resolver: WardrikOAuth.Case.Resolver, poll_floor: 0

# A daemon started by a test serves the HTTP API on whatever port is free.
config :wardrik, WardrikHTTP, port: 0

# Budgets are kept by meters the application starts, as a release does, and
# tool workers join a group it starts.
config :wardrik, :children, [WardrikPolicy.Supervisor, WardrikHTTP.Workers]

# The MCP client library logs every transport failure at error level. The
# suite reaches servers that are down on purpose, and the test around each one
# asserts on what the connection does about it.
config :anubis_mcp, log: false

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
