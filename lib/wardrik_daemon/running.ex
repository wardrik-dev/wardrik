defmodule WardrikDaemon.Running do
  @moduledoc """
  Runs the daemon once its store is up. `WardrikDaemon.Server` starts it.

  It reads `config.yaml` and `policies/`, filling in each `${NAME}` the environment doesn't set from
  the vault. Then it starts, in order:

    1. `WardrikBrave`, for `web_search`.
    2. Wardrik, deciding what each scope may do with `WardrikDaemon.Authorizer`.
    3. The HTTP API, as `WardrikDaemon.HTTP`, reached with `WardrikDaemon.Tokens`.
    4. A task that defines the agents in `agents/`, writes the `wardrik` command's token, and
       emits `[:wardrik_daemon, :started]`.

  A reload that finds `config.yaml` or `policies/` changed restarts it, to read them again. The
  HTTP API stops first, answering the requests it has, then the rest. If they don't read, it keeps
  running as it is, and the log says why.
  """

  use Supervisor

  require Logger

  alias WardrikCore.Principal
  alias WardrikDaemon.Agents
  alias WardrikDaemon.CLIToken
  alias WardrikDaemon.Config
  alias WardrikDaemon.Dirs
  alias WardrikDaemon.Policies

  @doc "Starts it, with the options `WardrikDaemon.Server` passes."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl Supervisor
  def init(opts) do
    %{name: name, dirs: dirs, env: env, store: store, keys: keys} = Map.new(opts)

    read = fn -> read(dirs, env, sealed(store, keys)) end
    {config, policies} = started = WardrikDaemon.ok!(read.())
    running = self()
    orgs = %{org: config.org, orgs: config.orgs, policies: policies}
    daemon = WardrikStore.scope(store, "wardrik_daemon")

    agents = [
      wardrik: name,
      dir: Dirs.config(dirs, "agents"),
      config: config,
      restart: fn -> restart(running, read.(), started) end,
      store: daemon
    ]

    wardrik =
      Wardrik.new(
        [
          name: name,
          capabilities: opts[:capabilities] || WardrikDaemon.Capabilities.all(name),
          store: store,
          keys: keys,
          mcp: config.mcp,
          channels: config.channels,
          notify: config.notify,
          workspace: config.workspace,
          defaults: config.defaults,
          prices: config.prices,
          policies: Map.to_list(policies),
          resolver:
            {WardrikDaemon.Resolver,
             Map.merge(orgs, %{wardrik: name, config: config, store: daemon})},
          key_source: {WardrikDaemon.Keys, wardrik: name, deployment: config.deployment_keys},
          authorizer: {WardrikDaemon.Authorizer, config.access},
          trusted_workers: config.trusted_workers,
          egress: &Wardrik.Egress.any/1,
          declarations: {Agents, agents}
        ] ++ config.wardrik ++ oauth(config)
      )

    children = [
      {WardrikBrave, name: WardrikDaemon.Capabilities.brave(name), api_key: config.brave},
      {Wardrik, wardrik},
      {WardrikDaemon.HTTP,
       wardrik: name,
       authenticator: {WardrikDaemon.Authenticator, daemon},
       store: daemon,
       orgs: orgs,
       port: config.port,
       ip: config.ip},
      %{
        id: :started,
        start: {Task, :start_link, [fn -> started(agents, dirs, config) end]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Returns a `t:WardrikDaemon.Config.vault/0` that reads the deployment's secrets from `store` with `keys`."
  @spec sealed(WardrikStore.t(), [String.t()]) :: Config.vault()
  def sealed(store, keys) do
    fn name ->
      case WardrikVault.read(store, %Principal{id: "deployment"}, name, keys: keys) do
        {:ok, value} -> {:ok, value}
        {:error, _reason} -> :error
      end
    end
  end

  defp read(dirs, env, vault) do
    with {:ok, config} <- Config.read(dirs, env, vault),
         {:ok, policies} <- Policies.read(Dirs.config(dirs, "policies")),
         do: {:ok, {config, policies}}
  end

  defp restart(_running, {:ok, same}, same), do: false

  defp restart(running, {:ok, _changed}, _started) do
    Logger.info("Wardrik restarts to read config.yaml and policies/ as they are now.")
    _stopper = spawn(fn -> Supervisor.stop(running, :shutdown) end)
    true
  end

  defp restart(_running, {:error, why}, _started) do
    Logger.warning("Wardrik kept config.yaml and policies/ as they read at start. #{why}")
    false
  end

  defp oauth(%Config{oauth: nil}), do: []
  defp oauth(%Config{oauth: oauth}), do: [oauth: oauth]

  defp started(agents, dirs, config) do
    Enum.each(config.warnings, &Logger.warning("config.yaml: #{&1}"))
    _problems = Agents.reload(agents)
    :ok = CLIToken.issue(agents[:store], Dirs.data_home(dirs, "cli_token"), Config.url(config))
    :telemetry.execute([:wardrik_daemon, :started], %{}, %{wardrik: agents[:wardrik]})
  end
end
