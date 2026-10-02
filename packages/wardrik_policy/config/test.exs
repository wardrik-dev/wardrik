import Config

config :logger, level: :warning

config :wardrik, Wardrik.Store, adapter: Wardrik.Store.Memory

config :wardrik, Wardrik.Fleet, org: "default"

# Budgets are kept by meters, and tool workers join a group, that core
# starts as a release does.
config :wardrik, :children, [WardrikPolicy.Supervisor]

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
