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
config :wardrik_daemon, WardrikDaemon.SSH,
  entrypoint: {WardrikTUI.SSH, options: {WardrikDaemon.Agents, :options, []}}

# Wardrik is started by Wardrikd.Application, after the applications of the
# store config.yaml names, rather than with its own.
config :wardrik, start: :host

# A tool's key the vault holds for nobody a call reaches is read from the
# environment variable of its name, as the deployment's.
config :wardrik_daemon, WardrikVault, environment: ["BRAVE_API_KEY"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

if config_env() in [:prod, :test], do: import_config("#{config_env()}.exs")
