defmodule WardrikDaemon do
  @moduledoc """
  The host a `wardrik` release runs: `host/2` composes it from
  `config.yaml`, and `WardrikDaemon.Tree` starts `Wardrik` on it, which
  starts core, then the host's children, in order, each handed the host:

    * `WardrikDaemon.Host`, which holds the host and the config for the
      `wardrik` commands that reach the node over rpc
    * this supervisor, which reads the agent and policy files once, as
      `wardrik reload` does (see `WardrikDaemon.Agents`), so nothing after
      it finds a deployment half read, and starts `WardrikDaemon.SSH`,
      which serves the TUI over SSH, where `ssh/authorized_keys` in the
      config directory lets anyone in

  then what `attach/2` attaches, each package with its own section of the
  config as options:

    * `WardrikMCP.Supervisor`, with the servers configured and those orgs and
      people add, kept in the store. Each command's stderr goes to
      `log/mcp.log` in the state directory.
    * `WardrikOAuth.Supervisor`, when a provider is configured, or the vault
      has a key to keep the tokens of servers people add and sign in to.
    * `WardrikNotify.Supervisor`, when a notify target is configured. It
      follows every agent's log as `deployment`, which
      `WardrikDaemon.Issuer` allows `agent.events`, reading each agent's
      route from its definition as its events come.
    * `WardrikChannel.Replies`, which posts what agents answer in the rooms'
      threads, and `WardrikChannel.Supervisor`, which runs what each
      channel's adapter runs, such as its connection to the medium, when a
      channel is configured, each installed in the workspace its `token`
      reaches.
    * `WardrikHTTP.Access`, the tool workers' group, and
      `WardrikHTTP.Listener`, which serves the HTTP API on loopback, or
      where `http` says, to callers holding a token that `wardrik token
      create` made, on the host; and its routes: under `/v1/channels/`, what
      each channel's medium sends it, such as Slack's events, answered by
      the channel, and, where `WardrikOAuth.Supervisor` runs, the pages a
      browser comes back to from a sign-in, under the redirect URL's path;
      see `WardrikOAuth.Callback`.

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
    # The files are read before what serves the agents starts, so nothing
    # it serves finds an agent its file does not yet define.
    _reloaded = Wardrik.Definitions.reload(Wardrik.Host.definitions(host), host: host)

    # The MCP servers started below write their commands' output there.
    # credo:disable-for-next-line Wardrik.Credo.Check.InitDoesNoIO
    File.mkdir_p!(Path.dirname(stderr(config)))

    Supervisor.init(WardrikDaemon.SSH.children(config, host: host), strategy: :one_for_one)
  end

  @doc """
  The host a daemon running under `config` offers, as `Wardrik.new/1` makes
  it, keeping everything in `store`: its definitions, read under
  `WardrikDaemon.Agents`; the vault the config's
  keys unseal, as its credentials, granting through `WardrikOAuth` with the
  config's `oauth`; the accounts people connect through both; the HTTP API's
  tokens, lasting as long as `config.yaml`'s `tokens.expires.api` says;
  webhooks checked with the secret the vault holds for each agent's owner;
  `WardrikDaemon.Issuer`, whose tokens last as long as
  `tokens.expires.session` says; agents' files kept in the store; the MCP
  servers orgs and people add, kept there too; the model's runtime, pricing
  tools as `config.yaml`'s `tools` says; the daemon's own processes, the
  holder of the host and this supervisor, among its children; and what
  `attach/2` adds.
  """
  @spec host(Config.t(), store: WardrikStore.t()) :: Wardrik.Host.t()
  def host(%Config{} = config, opts) do
    store = Keyword.fetch!(opts, :store)
    oauth = oauth(config, store)
    vault_settings = Keyword.take(Config.section(config, WardrikVault), [:keys])
    vault = WardrikVault.new([store: store, grants: oauth] ++ vault_settings)
    agents = Agents.new(store: store, config: config)
    prices = config |> Config.section(WardrikDaemon.AgentFile) |> Keyword.get(:tool_prices, %{})

    [
      store: store,
      context: agents,
      connections: %WardrikOAuth.Connections{oauth: oauth, vault: vault},
      servers: %WardrikMCP.Servers{store: store, oauth: oauth, vault: vault},
      credentials: vault,
      tokens: %WardrikHTTP.Tokens{store: store},
      triggers: %WardrikTrigger.Deliveries{secrets: &Secrets.for_agent(vault, &1, &2)},
      issuer: %WardrikDaemon.Issuer{agents: agents},
      runtimes: [%Wardrik.LLM.Runtime{config: [tool_prices: prices]}]
    ]
    |> Kernel.++(Keyword.take(Config.section(config, Wardrik.Tokens), [:expires]))
    |> Wardrik.new()
    |> Wardrik.Host.child({WardrikDaemon.Host, config: config})
    |> Wardrik.Host.child({__MODULE__, config: config})
    |> attach(config)
  end

  @doc """
  `host` with what the daemon ships attached, and the packages `config`
  configures, each with its own section as options: web search, with the
  key `brave.api_key` gives it, deep research and Lua among its tools; the MCP servers configured and those
  owners add (see
  `WardrikMCP.attach/2`); where a provider is configured, or the vault has
  a key, the pages a sign-in comes back to; the notify targets and the
  channels configured; and the HTTP API, and the tool workers', `workers`.
  """
  @spec attach(Wardrik.Host.t(), Config.t()) :: Wardrik.Host.t()
  def attach(host, %Config{} = config) do
    host
    |> WardrikBrave.attach(Config.section(config, WardrikBrave))
    |> WardrikResearch.attach()
    |> WardrikLua.attach()
    |> WardrikMCP.attach([stderr: {:file, stderr(config)}] ++ Config.section(config, WardrikMCP))
    |> signs_in(config)
    |> WardrikNotify.attach(Config.section(config, WardrikNotify))
    |> WardrikChannel.attach(
      [org: Config.org(config)] ++
        Keyword.take(Config.section(config, WardrikChannel), [
          :channels,
          :installations,
          :orgs,
          :creates,
          :approvers
        ])
    )
    |> WardrikHTTP.attach(
      Keyword.take(Config.section(config, WardrikHTTP), [:port, :ip, :workers])
    )
  end

  # Each command's stderr goes to log/mcp.log in the state directory.
  defp stderr(config), do: Path.join([config.state_dir, "log", "mcp.log"])

  # The host this daemon built offers its own sign-ins, and those of the
  # servers people add, which keep their tokens in a vault with a key.
  defp signs_in(host, config) do
    oauth = oauth(config, Wardrik.Host.store(host))

    if WardrikOAuth.configured?(oauth) or
         Config.section(config, WardrikVault)[:keys] not in [nil, []],
       do: WardrikOAuth.attach(host, oauth: oauth),
       else: host
  end

  defp oauth(config, store) do
    added = %WardrikMCP.Servers.Providers{store: store}
    WardrikOAuth.new([audit: Wardrik.Audit, added: added] ++ Config.oauth_settings(config))
  end

  @doc """
  What this node is running, as `wardrik status` prints it: the node, how long
  it has been up, which of its cluster's nodes are connected, each agent in
  the fleet with what it is doing, on which node, and when a trigger asks it
  next, each agent or policy file that does not read, and each channel or
  notify target a definition names that `config.yaml` does not configure.
  """
  @spec status(Wardrik.Host.t(), Config.t()) :: String.t()
  def status(host, config) do
    agents = Agents.of(host)
    members = Fleet.list(Wardrik.Resource.parse!("*"), host: host)
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

    header =
      [
        "wardrik #{Application.spec(:wardrik_core, :vsn)} on #{Nodes.display(node())}, up #{duration(uptime_ms)}"
        | cluster(Config.section(config, Cluster))
      ] ++ ["#{length(members)} #{agents(members)}"]

    rows =
      for member <- members,
          do:
            Enum.join(
              [
                "  #{member.id}",
                Wardrik.Fleet.Member.label(member)
                | where(member) ++ spent(host, member.id) ++ next_run(member.id)
              ],
              "  "
            )

    broken =
      for {_path, {:error, message}} <- Agents.files(agents, host: host), do: "  #{message}"

    unbuilt = for message <- unbuilt(host), do: "  #{message}"

    Enum.join(
      header ++
        rows ++
        problems(broken, "file does not read", "files do not read") ++
        problems(unbuilt, "definition does not build", "definitions do not build") ++
        problems(unknown(host, config), "name is not configured", "names are not configured"),
      "\n"
    )
  end

  defp unbuilt(host) do
    definitions = Wardrik.Host.definitions(host)

    for %{id: id} <- Wardrik.Definitions.list(definitions, Wardrik.Resource.parse!("*")),
        {:error, message} <- [Wardrik.Definitions.spec(definitions, id, host: host)],
        do: "#{id} does not build from its definition: #{message}"
  end

  # A channel or notify target a definition names that config.yaml does not
  # configure, which offers or tells nothing.
  defp unknown(host, config) do
    channels = configured(config, WardrikChannel, :channels)
    targets = configured(config, WardrikNotify, :targets)

    for definition <-
          Wardrik.Definitions.list(Wardrik.Host.definitions(host), Wardrik.Resource.parse!("*")),
        {what, name, known} <-
          Enum.map(definition.channels, &{"channel", &1, channels}) ++
            Enum.map(routed(definition.notify), &{"notify target", &1, targets}),
        name not in known,
        do: "  #{definition.id} names the #{what} #{name}, which config.yaml does not configure"
  end

  defp configured(config, section, key),
    do:
      for(
        {name, _settings} <- Config.section(config, section) |> Keyword.get(key, []),
        do: Atom.to_string(name)
      )

  defp routed(nil), do: []
  defp routed(%WardrikDefinition.Route{targets: targets}), do: targets

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
        :erpc.call(daemon, Process, :whereis, [WardrikDaemon.Host]) != nil,
        do: daemon
  end

  @doc """
  What the agent `key` has spent of each budget the spec its kept definition
  writes on `host` gives it, as its budgets say it; nothing where none is
  kept.
  """
  @spec spent(Wardrik.Host.t(), Wardrik.AgentAddress.t()) :: [String.t()]
  def spent(host, key) do
    agent = Wardrik.AgentAddress.agent(key)

    case Wardrik.Definitions.spec(Wardrik.Host.definitions(host), agent, host: host) do
      {:ok, spec} -> spent_by(spec, key)
      {:error, _reason} -> []
    end
  end

  # Budgets an agent spends alone, and ceilings its org spends together.
  @budgets [WardrikPolicy.Budget, WardrikPolicy.Ceiling]

  @doc """
  What the agent `key` has spent of each budget `spec` gives it, as its
  budgets say it, each named for its policy where it has more than one. An
  org's policy says what all of the org's agents have spent together.
  """
  @spec spent_by(Wardrik.Agent.Spec.t() | nil, Wardrik.AgentAddress.t()) :: [String.t()]
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
  @spec next_in(Wardrik.AgentAddress.t()) :: non_neg_integer() | nil
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
