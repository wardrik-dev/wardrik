import Config

# None of os_mon's port programs run: each prints "Erlang has closed" on the
# terminal when the VM exits.
config :os_mon, start_cpu_sup: false, start_disksup: false, start_memsup: false

# BackBreeze sizes its render cache from :os_mon when it can; cap it anyway.
config :back_breeze, render_cache_max_memory_bytes: 256 * 1_024 * 1_024

# Credentials are kept in the vault, and accounts users connect through OAuth
# are grants it holds. A tool's key it holds for nobody is read from the
# environment variable of its name. `mix wardrik` starts it with these.
config :wardrik_sdk, WardrikVault, grants: WardrikOAuth, environment: ["BRAVE_API_KEY"]

if config_env() == :dev, do: import_config("dev.exs")
if config_env() == :test, do: import_config("test.exs")
