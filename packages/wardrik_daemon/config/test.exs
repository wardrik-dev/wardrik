import Config

config :logger, level: :warning

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

config :wardrik, Wardrik.Fleet, org: "default"

config :wardrik_brave, WardrikBrave,
  api_key: "test-brave-api-key",
  base_url: "https://brave.test",
  req_options: [plug: {Req.Test, WardrikBrave.Stub}, retry: false]

config :wardrik_notify, WardrikNotify, req_options: [plug: {Req.Test, WardrikNotify.Stub}]

# A connection that retries, or waits out a burst of tool changes, does so in
# milliseconds rather than a second or a quarter of one.
config :wardrik_mcp, WardrikMCP, first_retry: 10, refresh_after: 10

# The MCP client library logs every transport failure at error level. The
# suite reaches servers that are down on purpose, and the test around each one
# asserts on what the connection does about it.
config :anubis_mcp, log: false

# A daemon started by a test serves the HTTP API on whatever port is free.
config :wardrik_http, WardrikHTTP, port: 0

# What the daemon serves over SSH, as a release that carries the TUI names it.
config :wardrik_daemon, WardrikDaemon.SSH,
  entrypoint: {WardrikTUI.SSH, options: {WardrikDaemon.Agents, :options, []}}

# Budgets are kept by meters, and tool workers join a group, that core
# starts as a release does.
config :wardrik, :children, [WardrikPolicy.Supervisor, WardrikHTTP.Access, WardrikHTTP.Workers]

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
