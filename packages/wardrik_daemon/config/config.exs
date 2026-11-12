import Config

config :logger, level: if(config_env() == :test, do: :warning, else: :info)

# Connections for agents' streamed turns, per provider host: ReqLLM's 8 by default.
config :req_llm, stream_pool_size: 64
