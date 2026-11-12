defmodule WardrikDaemon.Running do
  @moduledoc """
  Runs the daemon once its store is up. `WardrikDaemon.Server` starts it.

  It reads `config.yaml` and `policies/`, then starts:

    1. `WardrikBrave`, for `web_search`, and `WardrikGateway`, which every model call goes
       through.
    2. Wardrik, with `WardrikDaemon.Authorizer` and `WardrikDaemon.OAuthApps`.
    3. `WardrikDaemon.Pairings`.
    4. `WardrikDaemon.Web.Endpoint`, the dashboard, unless `web.enabled` is `false`.
    5. `WardrikDaemon.HTTP`. Nodes of a cluster share its port; see `WardrikDaemon.Cluster`.
    6. A task that starts added MCP servers, defines the agents, writes `cli_token`, and emits
       `[:wardrik_daemon, :started]`.

  A reload that finds `config.yaml` or `policies/` changed restarts it. If they don't read, it
  keeps running and logs why.
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
    daemon = Wardrik.Store.scope(store, "wardrik_daemon")
    gateway = gateway(name)
    web = if config.web, do: WardrikDaemon.Web.key(keys)

    own = %{
      wardrik: name,
      store: daemon,
      orgs: orgs,
      config: config,
      dirs: dirs,
      env: env,
      web: web
    }

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
          capabilities:
            WardrikDaemon.Capabilities.all(own) ++
              WardrikDaemon.Harnesses.capabilities(name, daemon, config) ++
              (opts[:capabilities] || []),
          store: store,
          vault_keys: keys,
          mcp: config.mcp,
          channels: config.channels,
          notify: config.notify,
          defaults: config.defaults,
          prices: config.prices,
          model_options: config.model_options,
          middleware: [{WardrikGateway, gateway}],
          policies: Map.to_list(policies),
          resolver:
            {WardrikDaemon.Resolver,
             Map.merge(orgs, %{wardrik: name, config: config, store: daemon})},
          key_source: {WardrikDaemon.Keys, wardrik: name, deployment: config.deployment_keys},
          authorizer: {WardrikDaemon.Authorizer, %{access: config.access, store: daemon}},
          trusted_workers: config.trusted_workers,
          egress: WardrikDaemon.Egress.check(config),
          declarations: {Agents, agents}
        ] ++ config.wardrik ++ oauth(config, %{wardrik: name, config: config, store: daemon})
      )

    children =
      [
        {WardrikBrave,
         name: WardrikDaemon.Capabilities.brave(name),
         api_key: config.brave,
         key_help: WardrikDaemon.Capabilities.brave_help()},
        {WardrikGateway, [name: gateway] ++ config.gateway},
        {WardrikACP,
         name: WardrikDaemon.Harnesses.acp(name),
         worktrees: Dirs.data_home(dirs, "worktrees"),
         checkouts: config.checkouts,
         harnesses: config.harnesses},
        {Wardrik, wardrik},
        {WardrikDaemon.Pairings, name: WardrikDaemon.Pairings.name(name)}
      ] ++
        dashboard(web, own) ++
        [
          {WardrikDaemon.HTTP,
           [
             wardrik: name,
             authenticator: {WardrikDaemon.Authenticator, daemon},
             store: daemon,
             orgs: orgs,
             config: config,
             web: web,
             port: config.port,
             ip: config.ip
           ] ++ shared(config.cluster)},
          %{
            id: :started,
            start: {Task, :start_link, [fn -> started(agents, dirs, config) end]},
            restart: :transient
          }
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp gateway(name), do: Module.concat(name, Gateway)

  defp dashboard(nil, _daemon), do: []

  defp dashboard(key, daemon),
    do: [
      {
        WardrikDaemon.Web.Endpoint,
        # WardrikDaemon.HTTP forwards requests to it. It doesn't open its own port.
        secret_key_base: key,
        daemon: daemon,
        server: false,
        live_view: [signing_salt: "wardrik web live"]
      }
    ]

  # Nodes on one machine share the HTTP API's port.
  defp shared(nil), do: []
  defp shared(_cluster), do: [retry: :timer.seconds(5)]

  @doc "Returns a `t:WardrikDaemon.Config.vault/0` that reads the deployment's secrets from `store` with `keys`."
  @spec sealed(Wardrik.Store.t(), [String.t()]) :: Config.vault()
  def sealed(store, keys) do
    fn name ->
      case Wardrik.Vault.read(store, %Principal{id: "deployment"}, name, keys: keys) do
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

  defp oauth(%Config{oauth: nil}, _daemon), do: []

  # config.yaml's providers are the deployment's apps, which WardrikDaemon.OAuthApps gives.
  defp oauth(%Config{oauth: oauth}, daemon),
    do: [
      oauth: Keyword.delete(oauth, :providers) ++ [resolver: {WardrikDaemon.OAuthApps, daemon}]
    ]

  defp started(agents, dirs, config) do
    Enum.each(config.warnings, &Logger.warning("config.yaml: #{&1}"))
    :ok = WardrikDaemon.Servers.start(agents[:wardrik], agents[:store])
    _problems = Agents.reload(agents)
    :ok = CLIToken.issue(agents[:store], Dirs.data_home(dirs, "cli_token"), Config.url(config))
    :telemetry.execute([:wardrik_daemon, :started], %{}, %{wardrik: agents[:wardrik]})
  end
end
