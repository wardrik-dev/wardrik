import Config

config :req_llm, stream_pool_count: 128

# BackBreeze sizes its render cache from :os_mon when it can; cap it anyway.
# None of os_mon's port programs run: each prints "Erlang has closed" on the
# terminal when the VM exits.
config :back_breeze, render_cache_max_memory_bytes: 256 * 1_024 * 1_024

config :os_mon, start_cpu_sup: false, start_disksup: false, start_memsup: false

# What the daemon serves over SSH: the TUI, which nothing in the daemon's own
# code names, starting agents as config.yaml's defaults say. A build without
# the TUI leaves this out and serves nothing there.
config :wardrik, WardrikDaemon.SSH,
  entrypoint: {WardrikTUI.SSH, options: {WardrikDaemon.Agents, :options, []}}

# The org an agent is in where nothing names one; config.yaml's org replaces it.
config :wardrik, Wardrik.Fleet, org: "default"

# Credentials are kept in the vault, and accounts users connect through OAuth
# are grants it holds.
config :wardrik, WardrikVault, grants: WardrikOAuth

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
