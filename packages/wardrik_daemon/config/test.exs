import Config

config :logger, level: :warning

# The fleet writes to a real store, so the suite gets one of its own, unique
# per run so two suites can run side by side. test_helper.exs removes it.
config :wardrik, WardrikStore,
  adapter: WardrikStore.EKV,
  data_dir:
    Path.join([
      System.tmp_dir!(),
      "wardrik-test",
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    ])

# What the daemon starts each package with, beside what config.yaml says.
config :wardrik_daemon, WardrikNotify, req_options: [plug: {Req.Test, WardrikNotify.Stub}]

# A connection that retries, or waits out a burst of tool changes, does so in
# milliseconds rather than a second or a quarter of one.
config :wardrik_daemon, WardrikMCP, first_retry: 10, refresh_after: 10

# The MCP client library logs every transport failure at error level. The
# suite reaches servers that are down on purpose, and the test around each one
# asserts on what the connection does about it.
config :anubis_mcp, log: false

# A daemon started by a test serves the HTTP API on whatever port is free.
config :wardrik_daemon, WardrikHTTP, port: 0

# What the daemon serves over SSH, as a release that carries the TUI names it.
config :wardrik_daemon, WardrikDaemon.SSH,
  entrypoint: {WardrikTUI.SSH, options: {WardrikDaemon.Agents, :options, []}}

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000

# A channel adapter of the suite's own, as wardrik_slack names WardrikSlack.
config :wardrik_daemon, :wardrik_channels, test: WardrikDaemon.Test.Channel
