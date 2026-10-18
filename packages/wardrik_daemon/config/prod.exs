import Config

config :logger, level: :info

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :req_llm, stream_pool_count: 128, redact_context: true

# The search key every agent may read: the deployment's, sealed with
# `wardrik vault put BRAVE_API_KEY`, or the environment variable of its name.
config :wardrik_daemon, WardrikVault, shared: ["BRAVE_API_KEY"]
