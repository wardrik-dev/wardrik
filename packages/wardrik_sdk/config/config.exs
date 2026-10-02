import Config

# None of os_mon's port programs run: each prints "Erlang has closed" on the
# terminal when the VM exits.
config :os_mon, start_cpu_sup: false, start_disksup: false, start_memsup: false

# BackBreeze sizes its render cache from :os_mon when it can; cap it anyway.
config :back_breeze, render_cache_max_memory_bytes: 256 * 1_024 * 1_024

# The org an agent is in where nothing names one.
config :wardrik, Wardrik.Fleet, org: "default"

# Credentials are kept in the vault, and accounts users connect through OAuth
# are grants it holds.
config :wardrik_vault, WardrikVault, grants: WardrikOAuth

if config_env() == :dev, do: import_config("dev.exs")
if config_env() == :test, do: import_config("test.exs")
