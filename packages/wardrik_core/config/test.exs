import Config

# Print only warnings and errors during test
config :logger, level: :warning

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  anthropic_api_key: "test-key",
  openai_api_key: "test-key",
  receive_timeout: 1_000
