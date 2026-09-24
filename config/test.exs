import Config

config :logger, level: :warning

config :tars, TarsBrave,
  api_key: "test-brave-api-key",
  base_url: "https://brave.test",
  req_options: [plug: {Req.Test, TarsBrave.Stub}, retry: false]

# The fleet writes to a real store, so the suite gets one of its own, unique
# per run so two suites can run side by side. test_helper.exs removes it.
config :tars, Tars.Store,
  adapter: Tars.Store.EKV,
  data_dir:
    Path.join([
      System.tmp_dir!(),
      "tars-test",
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    ])

# Budgets are kept by meters the application starts, as a release does.
config :tars, :children, [TarsPolicy.Supervisor]

# The MCP client library logs every transport failure at error level. The
# suite reaches servers that are down on purpose, and the test around each one
# asserts on what the connection does about it.
config :anubis_mcp, log: false

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
