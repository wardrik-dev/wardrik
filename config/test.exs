import Config

config :logger, level: :warning

config :tars, TarsBrave,
  api_key: "test-brave-api-key",
  base_url: "https://brave.test",
  req_options: [plug: {Req.Test, TarsBrave.Stub}, retry: false]

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
