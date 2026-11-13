import Config

config :logger, level: if(config_env() == :test, do: :warning, else: :info)

# Connections for agents' streamed turns, per provider host: ReqLLM's 8 by default.
config :req_llm, stream_pool_size: 64

# Local, fine-tuned and endpoint models are often missing from ReqLLM's catalog, which would
# otherwise print a warning with a stack trace on every call to one.
config :req_llm, warn_unverified_models: false
