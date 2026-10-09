import Config

config :logger, level: :warning

config :wardrik, WardrikStore, adapter: WardrikStore.Memory

# The MCP client library logs every transport failure at error level.
config :anubis_mcp, log: false

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
