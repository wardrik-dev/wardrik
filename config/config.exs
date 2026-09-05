import Config

config :tars,
  composio_base_url: "https://backend.composio.dev/api/v3.1",
  brave_base_url: "https://api.search.brave.com"

config :req_llm, stream_pool_count: 128

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
