import Config

config :logger, level: :warning

config :wardrik, Wardrik.Store, adapter: Wardrik.Store.Memory

config :wardrik, Wardrik.Fleet, org: "default"

# A connection that retries, or waits out a burst of tool changes, does so in
# milliseconds rather than a second or a quarter of one.
config :wardrik_mcp, WardrikMCP, first_retry: 10, refresh_after: 10

# The MCP client library logs every transport failure at error level. The
# suite reaches servers that are down on purpose, and the test around each one
# asserts on what the connection does about it.
config :anubis_mcp, log: false

# OAuth hosts resolve without DNS, and a device flow polls as often as the
# test's stub server asks.
config :wardrik_oauth, WardrikOAuth, resolver: WardrikOAuth.Case.Resolver, poll_floor: 0

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
