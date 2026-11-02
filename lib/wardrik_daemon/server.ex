defmodule WardrikDaemon.Server do
  @moduledoc """
  Runs the daemon.

      WardrikDaemon.Server.start_link(env: System.get_env())

    * It loads the env file, starts the store, then `WardrikDaemon.Running`.
    * The store is Postgres if `config.yaml` has `storage`, else the data directory.
    * The vault's keys are `vault.keys`, `WARDRIK_VAULT_KEY`, or `vault_key` in the data home,
      made on first start.
    * It emits `[:wardrik_daemon, :started]` once the agents are defined.

  ## Options

    * `:env` - required. The environment.
    * `:name` - the Wardrik's name. `WardrikDaemon.Wardrik` unless set.
    * `:capabilities` - the tools agents may name. `WardrikDaemon.Capabilities.all/2` unless set.
    * `:store` - a store to use instead of the one on disk, for tests.
  """

  use Supervisor

  alias WardrikDaemon.Config
  alias WardrikDaemon.Dirs
  alias WardrikDaemon.EnvFile

  @doc "Starts the daemon. Fails, with the reason, if `config.yaml` or a policy doesn't read."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    name = Keyword.get(opts, :name, WardrikDaemon.Wardrik)
    given = Keyword.fetch!(opts, :env)
    dirs = Dirs.new(given)
    env = EnvFile.load(dirs.env_file, given)
    System.put_env(env)

    boot = WardrikDaemon.ok!(Config.bootstrap(dirs, env))

    store = Keyword.get_lazy(opts, :store, fn -> store(boot.storage, name, dirs) end)

    running = [
      name: name,
      dirs: dirs,
      env: env,
      store: store,
      keys: keys(boot.keys, dirs, env),
      capabilities: opts[:capabilities]
    ]

    Supervisor.init([{WardrikStore, store}, {WardrikDaemon.Running, running}],
      strategy: :rest_for_one
    )
  end

  defp store(nil, name, dirs),
    do: WardrikStore.EKV.new(name: Module.concat(name, Store), data_dir: dirs.data)

  defp store({:postgres, url}, _name, _dirs), do: WardrikStore.Ecto.new(url: url)

  defp keys([_ | _] = keys, _dirs, _env), do: keys
  defp keys([], _dirs, %{"WARDRIK_VAULT_KEY" => key}), do: [key]
  defp keys([], dirs, _env), do: [vault_key(Dirs.data_home(dirs, "vault_key"))]

  defp vault_key(path) do
    case File.read(path) do
      {:ok, key} ->
        String.trim(key)

      {:error, :enoent} ->
        key = WardrikVault.generate_key()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, key)
        File.chmod!(path, 0o600)
        key
    end
  end
end
