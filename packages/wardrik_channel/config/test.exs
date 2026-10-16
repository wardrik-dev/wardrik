import Config

config :logger, level: :warning

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000

config :wardrik_channel, :wardrik_channels, test: WardrikChannel.Test.Adapter
