import Config

config :req_llm, stream_pool_count: 128

# BackBreeze sizes its render cache from :os_mon when it can; cap it anyway.
config :back_breeze, render_cache_max_memory_bytes: 256 * 1_024 * 1_024

config :os_mon, start_cpu_sup: false, start_disksup: false

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
