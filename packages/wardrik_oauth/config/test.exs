import Config

config :logger, level: :warning

config :wardrik, Wardrik.Store, adapter: Wardrik.Store.Memory

config :wardrik, Wardrik.Fleet, org: "default"

# OAuth hosts resolve without DNS, and a device flow polls as often as the
# test's stub server asks.
config :wardrik_oauth, WardrikOAuth, resolver: WardrikOAuth.Case.Resolver, poll_floor: 0

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
