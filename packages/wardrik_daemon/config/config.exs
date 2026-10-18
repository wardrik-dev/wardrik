import Config

# None of os_mon's port programs run: each prints "Erlang has closed" on the
# terminal when the VM exits.
config :os_mon, start_cpu_sup: false, start_disksup: false, start_memsup: false

# The TUI, over SSH or as `mix wardrik` attaches it, sizes its render cache
# from :os_mon when it can; cap it anyway.
config :back_breeze, render_cache_max_memory_bytes: 256 * 1_024 * 1_024

# What the daemon serves over SSH: the TUI, which nothing in the daemon's own
# code names. A build without the TUI leaves this out and serves nothing there.
config :wardrik_daemon, WardrikDaemon.SSH, entrypoint: {WardrikTUI.SSH, []}

import_config("#{config_env()}.exs")
