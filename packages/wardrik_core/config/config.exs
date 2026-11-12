# This file is responsible for configuring your application and its
# dependencies at compile time. Runtime values (secrets, anything read
# from the environment) belong in config/runtime.exs.
import Config

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
