defmodule WardrikDaemon do
  @moduledoc """
  The host a `wardrik` release runs beside core.

  `WardrikDaemon.Tree` starts it last, once it has read `config.yaml`,
  built the `Wardrik.Host` from it, and started core and what runs on the
  fleet; see there. It is handed that host and the `WardrikDaemon.Config`
  read, and starts what the config calls for, each with its own section as
  options:

    * `WardrikMCP.Supervisor`, when a server is configured. Each command's stderr
      goes to `log/mcp.log` in the state directory.
    * `WardrikOAuth.Supervisor`, when a provider is configured.
    * `WardrikDaemon.Agents`, which runs the agents `agents/` declares, as
      the host's definitions.
    * `WardrikNotify.Supervisor`, when a notify target is configured. It asks
      `WardrikDaemon.Agents.routes/1` for the routes as it starts, so one that
      restarts routes the agents as before.
    * `WardrikChannel.Supervisor`, when a channel is configured, which runs
      what each channel's adapter runs, such as its connection to the medium,
      after `WardrikChannel.Replies`, which posts what agents answer in its
      rooms' threads. Both are handed the channels `WardrikChannel.channels/2`
      makes once from the channels' settings, on the host.
    * `WardrikDaemon.SSH`, which serves the TUI over SSH, where `ssh/authorized_keys`
      in the config directory lets anyone in.
    * `WardrikHTTP.Listener`, which serves the HTTP API on loopback, or where
      `http` says, to callers holding a token that `wardrik token create`
      made, on the host.

  `:host` and `:config` are required.

  ## From a shell

  The release's `bin/wardrik` drives it:

      wardrik serve     # in the foreground, logging to the terminal
      wardrik start     # in the background, logging to the state directory
      wardrik status    # what is running
      wardrik doctor    # whether config.yaml reads, and the store it names answers
      wardrik reload    # read agents/ and policies/ again
      wardrik parked    # what is waiting on a person
      wardrik triggers # when each trigger runs next, and how it last ran
      wardrik agent spawn NAME   # start an agent, writing its file from defaults
      wardrik agent rm KEY       # remove one, its conversation and triggers
      wardrik approve KEY CALL
      wardrik deny KEY CALL [REASON]
      wardrik token create NAME --scope PREFIX --policy NAME   # a token for the HTTP API
      wardrik vault put NAME   # seal a secret, asking for its value
      wardrik attach    # the TUI, over SSH
      wardrik remote    # an IEx shell on the node
      wardrik logs      # follow the log
      wardrik stop
  """

  use Supervisor

  alias Wardrik.Fleet
  alias WardrikConsole.Nodes
  alias WardrikDaemon.Agents
  alias WardrikDaemon.Cluster
  alias WardrikDaemon.Config
  alias WardrikDaemon.Secrets

  @spec start_link(host: Wardrik.Host.t(), config: Config.t()) :: Supervisor.on_start()
  def start_link(opts) do
    started = Map.new(Keyword.validate!(opts, [:host, :config]))
    Supervisor.start_link(__MODULE__, started, name: __MODULE__)
  end

  @impl true
  def init(%{host: host, config: config}) do
    store = Wardrik.Host.store(host)
    agents = Wardrik.Host.definitions(host)

    children =
      mcp(config, store) ++
        oauth(host) ++
        [{Agents, agents: agents}] ++
        channels(config, host, agents) ++
        notify(config, agents) ++
        WardrikDaemon.SSH.children(config, host: host) ++
        [{WardrikHTTP.Listener, [host: host] ++ listener(config)}]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  The host a daemon running under `config` offers, keeping everything in
  `store`: its definitions, `WardrikDaemon.Agents`; the vault the config's
  keys unseal, as its credentials, granting through `WardrikOAuth` with the
  config's `oauth`; the accounts people connect through both; the HTTP API's
  tokens; webhooks checked with the vault's secrets for each agent, else the
  environment's; `WardrikDaemon.Grants`; and agents' files kept in the
  store.
  """
  @spec host(Config.t(), store: WardrikStore.t()) :: Wardrik.Host.t()
  def host(%Config{} = config, opts) do
    store = Keyword.fetch!(opts, :store)
    audit = Wardrik.Audit
    oauth = WardrikOAuth.new([audit: audit] ++ oauth_settings(config))
    vault_settings = Keyword.take(Config.section(config, WardrikVault), [:keys, :shared])
    vault = WardrikVault.new([store: store, grants: oauth] ++ vault_settings)
    agents = Agents.new(store: store, config: config, audit: audit)

    Wardrik.Host.new(
      store: store,
      audit: audit,
      definitions: agents,
      connections: %WardrikOAuth.Connections{oauth: oauth, vault: vault},
      credentials: vault,
      tokens: %WardrikHTTP.Tokens{store: store},
      triggers: %WardrikTrigger.Deliveries{
        secrets: &Secrets.for_agent(vault, &1, &2),
        verifiers: config.triggers.verifiers
      },
      grants: %WardrikDaemon.Grants{store: store, agents: agents},
      workspace: %WardrikWorkspace.Backend.Store{store: store}
    )
  end

  defp oauth_settings(config),
    do: Keyword.take(Config.section(config, WardrikOAuth), [:client, :providers, :redirect])

  defp mcp(config, store) do
    settings = Config.section(config, WardrikMCP)

    if Keyword.get(settings, :servers, []) != [] do
      stderr = Path.join([config.state_dir, "log", "mcp.log"])
      File.mkdir_p!(Path.dirname(stderr))
      [{WardrikMCP.Supervisor, [store: store, stderr: {:file, stderr}] ++ settings}]
    else
      []
    end
  end

  # The host this daemon built offers its own sign-ins.
  defp oauth(host) do
    %WardrikOAuth.Connections{oauth: oauth} = Wardrik.Host.connections(host)

    if WardrikOAuth.configured?(oauth),
      do: [{WardrikOAuth.Supervisor, oauth: oauth}],
      else: []
  end

  defp notify(config, agents) do
    settings = Config.section(config, WardrikNotify)

    if Keyword.get(settings, :targets, []) != [],
      do: [{WardrikNotify.Supervisor, [routes: {Agents, :routes, [agents]}] ++ settings}],
      else: []
  end

  defp channels(config, host, agents) do
    case Keyword.get(Config.section(config, WardrikChannel), :channels, []) do
      [] ->
        []

      configured ->
        channels =
          WardrikChannel.channels(configured,
            host: host,
            offered: {Agents, :offered, [agents]},
            creatable: {Agents, :creatable?, [agents]},
            create: {Agents, :create_in, [agents]},
            start: {Agents, :start, [agents]},
            approvers: {Agents, :asked, [agents]}
          )

        [
          {WardrikChannel.Replies, channels: channels, store: Wardrik.Host.store(host)},
          {WardrikChannel.Supervisor, channels: channels}
        ]
    end
  end

  # Tool workers' answers are the deployment's own where `http` trusts them.
  defp listener(config) do
    http = Config.section(config, WardrikHTTP)

    [workers: [trusted: Keyword.get(http, :trusted_workers, false)]] ++
      Keyword.take(http, [:port, :ip])
  end

  @doc """
  What this node is running, as `wardrik status` prints it: the node, how long
  it has been up, which of its cluster's nodes are connected, each agent in
  the fleet with what it is doing, on which node, and when a trigger asks it
  next, and each agent or policy file that does not read.
  """
  @spec status(Wardrik.Host.t(), Config.t()) :: String.t()
  def status(host, config) do
    agents = Wardrik.Host.definitions(host)
    members = Fleet.list()
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

    header =
      [
        "wardrik #{Application.spec(:wardrik, :vsn)} on #{Nodes.display(node())}, up #{duration(uptime_ms)}"
        | cluster(Config.section(config, Cluster))
      ] ++ ["#{length(members)} #{agents(members)}"]

    rows =
      for member <- members,
          do:
            Enum.join(
              [
                "  #{member.id}",
                Wardrik.Fleet.Member.label(member)
                | where(member) ++ spent(agents, member.id) ++ next_run(member.id)
              ],
              "  "
            )

    broken = for {_path, {:error, message}} <- Agents.files(agents), do: "  #{message}"
    unbuilt = for message <- Agents.problems(agents), do: "  #{message}"

    Enum.join(
      header ++
        rows ++
        problems(broken, "file does not read", "files do not read") ++
        problems(unbuilt, "definition does not build", "definitions do not build"),
      "\n"
    )
  end

  @doc """
  The agent files that read, by the ID of the agent each declares, with its
  spec, from `files` as `WardrikDaemon.Agents.files/1` answers them.
  """
  @spec declared([WardrikDaemon.Agents.file()]) ::
          %{Wardrik.AgentID.t() => {Path.t(), Wardrik.Agent.Spec.t()}}
  def declared(files) do
    for {path, {:ok, %Wardrik.Agent.Spec{} = spec}} <- files,
        into: %{},
        do: {spec.id, {path, spec}}
  end

  @doc "This node and every node connected to it that runs a daemon of its own."
  @spec daemons() :: [node()]
  def daemons do
    for daemon <- [node() | Node.list()],
        :erpc.call(daemon, Process, :whereis, [WardrikDaemon.Agents]) != nil,
        do: daemon
  end

  @doc """
  What the agent `key` has spent of each budget the spec its kept definition
  writes gives it, as its budgets say it; nothing where none is kept.
  """
  @spec spent(Agents.t(), Wardrik.AgentID.t()) :: [String.t()]
  def spent(%Agents{store: store} = agents, key) do
    with {:ok, definition} <- WardrikDefinition.Record.of(store, key),
         {:ok, spec} <- Agents.build(agents, definition, key) do
      spent_by(spec, key)
    else
      {:error, _reason} -> []
    end
  end

  # Budgets an agent spends alone, and ceilings its org spends together.
  @budgets [WardrikPolicy.Budget, WardrikPolicy.Ceiling]

  @doc """
  What the agent `key` has spent of each budget `spec` gives it, as its
  budgets say it, each named for its policy where it has more than one. An
  org's ceiling says what all of the org's agents have spent together.
  """
  @spec spent_by(Wardrik.Agent.Spec.t() | nil, Wardrik.AgentID.t()) :: [String.t()]
  def spent_by(%Wardrik.Agent.Spec{hooks: hooks}, key) when is_list(hooks) do
    budgets = for %Wardrik.Hook{module: module} = hook <- hooks, module in @budgets, do: hook

    for %Wardrik.Hook{name: name, module: module, value: budget} <- budgets,
        spent = module.spending(budget, key),
        spent != nil do
      if match?([_one], budgets), do: spent, else: "#{whose(Path.dirname(name))}: #{spent}"
    end
  end

  def spent_by(_spec, _key), do: []

  defp whose("policy"), do: "its own"
  defp whose(policy), do: policy

  @doc """
  How long until a trigger next asks the agent `key`, in milliseconds, or
  `nil` where none does on a clock.
  """
  @spec next_in(Wardrik.AgentID.t()) :: non_neg_integer() | nil
  def next_in(key) do
    case Enum.flat_map(WardrikTrigger.for_agent(key), & &1.next) do
      [] ->
        nil

      times ->
        next = Enum.min(times, DateTime)
        max(DateTime.diff(next, DateTime.utc_now(), :millisecond), 0)
    end
  end

  defp where(%{asleep: true}), do: []
  defp where(member), do: [Nodes.display(member.node)]

  defp next_run(key) do
    case next_in(key) do
      nil -> []
      ms -> ["next run in #{duration(ms)}"]
    end
  end

  defp cluster(cluster) do
    cond do
      not Cluster.configured?(cluster) ->
        []

      Cluster.named(cluster) == [] ->
        ["cluster of #{Cluster.size(cluster)}, found by DNS: " <> found(Cluster.members(cluster))]

      true ->
        {up, down} = Enum.split_with(Cluster.named(cluster), &(&1 in Cluster.members(cluster)))

        [
          "cluster of #{Cluster.size(cluster)}: " <>
            nodes(up, "up") <> nodes(down, "; ", "not connected")
        ]
    end
  end

  defp found([]), do: "none connected"
  defp found(nodes), do: Enum.map_join(nodes, ", ", &Nodes.display/1) <> " connected"

  defp nodes(nodes, prefix \\ "", state)
  defp nodes([], _prefix, _state), do: ""

  defp nodes(nodes, prefix, state),
    do: prefix <> Enum.map_join(nodes, ", ", &Nodes.display/1) <> " " <> state

  defp problems([], _one, _many), do: []
  defp problems([_line] = lines, one, _many), do: ["", "1 #{one}:" | lines]
  defp problems(lines, _one, many), do: ["", "#{length(lines)} #{many}:" | lines]

  defp agents([_member]), do: "agent"
  defp agents(_members), do: "agents"

  @doc false
  @spec duration(non_neg_integer()) :: String.t()
  def duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  def duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  def duration(ms), do: "#{div(ms, 3_600_000)}h #{div(rem(ms, 3_600_000), 60_000)}m"
end
