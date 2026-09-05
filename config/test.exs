import Config

config :logger, level: :warning

config :tars,
  composio_api_key: "test-composio-api-key",
  brave_api_key: "test-brave-api-key",
  brave_base_url: "https://brave.test"

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
