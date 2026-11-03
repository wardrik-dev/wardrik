import Config

config :logger, level: if(config_env() == :test, do: :warning, else: :info)
