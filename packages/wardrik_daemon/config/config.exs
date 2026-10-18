import Config

# None of os_mon's port programs run: each prints "Erlang has closed" on the
# terminal when the VM exits.
config :os_mon, start_cpu_sup: false, start_disksup: false, start_memsup: false

if config_env() in [:dev, :test], do: import_config("#{config_env()}.exs")
