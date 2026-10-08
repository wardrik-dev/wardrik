import Config

config :logger, level: :warning

config :wardrik, Wardrik.Store, adapter: Wardrik.Store.Memory

# Schedules run under a supervisor core starts as a release does.
config :wardrik, :children, [WardrikSchedule]

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
