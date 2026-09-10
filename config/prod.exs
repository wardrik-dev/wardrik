import Config

config :logger, level: :info

config :tars, TarsBrave, api_key: System.fetch_env!("BRAVE_API_KEY")

config :req_llm,
  redact_context: true,
  zai_api_key: System.fetch_env!("ZAI_API_KEY")
