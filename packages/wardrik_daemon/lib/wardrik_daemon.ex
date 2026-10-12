defmodule WardrikDaemon do
  @moduledoc """
  The host a `wardrik` release runs beside core.

  The release's tree starts it after core, `WardrikPolicy.Supervisor`, which
  keeps the budgets its agents' policies set, `WardrikSchedule`, which runs
  their schedules, `WardrikHTTP.Access`, which keeps what its tokens grant,
  and `WardrikHTTP.Workers`, the tool workers connected to the cluster, so
  all five start once the fleet is up. It gives core `WardrikDaemon.Cluster`
  as its `:cluster`, which starts before the fleet:

      children = [
        {Wardrik, cluster: [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]},
        WardrikPolicy.Supervisor,
        WardrikSchedule,
        WardrikHTTP.Access,
        WardrikHTTP.Workers,
        WardrikDaemon
      ]

      Supervisor.init(children, strategy: :rest_for_one)

  As its supervisor starts, it reads `config.yaml`, or `config.yml`, from the
  config directory into the settings it keeps (see `WardrikDaemon.Config`),
  starts `WardrikVault` with the vault's, and the key in the data home where
  nothing else gives it one (see `WardrikDaemon.VaultKey`), then starts what
  those settings call for, each with its own section as options:

    * `WardrikMCP.Supervisor`, when a server is configured. Each command's stderr
      goes to `log/mcp.log` in the state directory.
    * `WardrikOAuth.Supervisor`, when a provider is configured.
    * `WardrikDaemon.Agents`, which runs the agents `agents/` declares.
    * `WardrikNotify.Supervisor`, when a notify target is configured. It asks
      `WardrikDaemon.Agents.routes/0` for the routes as it starts, so one that
      restarts routes the agents as before.
    * `WardrikChannel.Supervisor`, when a channel is configured, which runs
      what each channel's adapter runs, such as its connection to the medium,
      after `WardrikChannel.Replies`, which posts what agents answer in its
      rooms' threads.
    * `WardrikDaemon.SSH`, which serves the TUI over SSH, where `ssh/authorized_keys`
      in the config directory lets anyone in.
    * `WardrikHTTP.Listener`, which serves the HTTP API on loopback, or where
      `http` says, to callers holding a token that `wardrik token create`
      made, and defines agents with `WardrikDaemon.Agents`.

  A `config.yaml` that does not read stops the boot, with the reason logged.

  `:config_dir`, `:state_dir` and `:data_dir` override
  `WardrikDaemon.Config.config_dir/0`, `WardrikDaemon.Config.state_dir/0` and
  `WardrikDaemon.Config.data_dir/0`.

  ## From a shell

  The release's `bin/wardrik` drives it:

      wardrik serve     # in the foreground, logging to the terminal
      wardrik start     # in the background, logging to the state directory
      wardrik status    # what is running
      wardrik doctor    # whether config.yaml reads, and the store it names answers
      wardrik reload    # read agents/ and policies/ again
      wardrik parked    # what is waiting on a person
      wardrik schedules # when each schedule runs next, and how it last ran
      wardrik agent spawn NAME   # start an agent, writing its file from defaults
      wardrik agent rm KEY       # remove one, its conversation and schedules
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

  require Logger

  alias Wardrik.Fleet
  alias WardrikConsole.Nodes
  alias WardrikDaemon.Cluster
  alias WardrikDaemon.Config
  alias WardrikDaemon.Secrets
  alias WardrikDaemon.VaultKey

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    dirs = {
      Keyword.get_lazy(opts, :config_dir, &Config.config_dir/0),
      Keyword.get_lazy(opts, :state_dir, &Config.state_dir/0),
      Keyword.get_lazy(opts, :data_dir, &Config.data_dir/0)
    }

    Supervisor.start_link(__MODULE__, dirs, name: __MODULE__)
  end

  @impl true
  def init({config_dir, state_dir, data_dir}) do
    case boot(config_dir, data_dir) do
      :ok ->
        children =
          mcp(Path.join([state_dir, "log", "mcp.log"])) ++
            oauth() ++
            [{WardrikDaemon.Agents, dir: config_dir}] ++
            channels() ++
            notify() ++
            WardrikDaemon.SSH.children(config_dir, data_dir) ++
            [{WardrikHTTP.Listener, listener()}]

        Supervisor.init(children, strategy: :one_for_one)

      {:error, message} ->
        Logger.error(message)
        exit({:config, message})
    end
  end

  # The vault's key comes first, from vault.keys, the environment or the key
  # file, so the rest of config.yaml can read from the vault what the
  # environment does not set.
  defp boot(config_dir, data_dir) do
    with {:ok, file} <- Config.file(config_dir),
         {:ok, vault} <- Config.read(file, only: ["vault"]),
         :ok <- Config.apply(Keyword.take(vault, [WardrikVault])),
         :ok <- vault_key(data_dir),
         {:ok, settings} <- Config.read(file, vault: &Secrets.named/1) do
      :ok = Config.apply(settings)
      Secrets.apply()
    end
  end

  # A key file that holds no key leaves the vault without one, as no file
  # does; wardrik doctor says why.
  defp vault_key(data_dir) do
    case VaultKey.load(data_dir) do
      {:error, message} -> Logger.warning("The vault has no key: " <> message)
      _loaded_or_none -> :ok
    end

    :ok
  end

  defp mcp(stderr) do
    settings = Config.settings(WardrikMCP)

    if Keyword.get(settings, :servers, []) != [] do
      File.mkdir_p!(Path.dirname(stderr))
      [{WardrikMCP.Supervisor, Keyword.put(settings, :stderr, {:file, stderr})}]
    else
      []
    end
  end

  defp oauth do
    settings = Config.settings(WardrikOAuth)

    if Keyword.get(settings, :providers, []) != [],
      do: [{WardrikOAuth.Supervisor, settings}],
      else: []
  end

  defp notify do
    settings = Config.settings(WardrikNotify)

    if Keyword.get(settings, :targets, []) != [],
      do: [{WardrikNotify.Supervisor, [routes: {WardrikDaemon.Agents, :routes, []}] ++ settings}],
      else: []
  end

  defp channels do
    case Keyword.get(Config.settings(WardrikChannel), :channels, []) do
      [] ->
        []

      channels ->
        [
          WardrikChannel.Replies,
          {WardrikChannel.Supervisor,
           channels: channels,
           offered: {WardrikDaemon.Agents, :offered, []},
           creatable: {WardrikDaemon.Agents, :creatable?, []},
           create: {WardrikDaemon.Agents, :create, []},
           start: {WardrikDaemon.Agents, :start, []},
           approvers: {WardrikDaemon.Agents, :approvers, []}}
        ]
    end
  end

  defp listener do
    [definition: WardrikDaemon.Agents] ++ Keyword.take(Config.settings(WardrikHTTP), [:port, :ip])
  end

  @doc """
  What this node is running, as `wardrik status` prints it: the node, how long
  it has been up, which of its cluster's nodes are connected, each agent in
  the fleet with what it is doing, on which node, and when a schedule asks it
  next, and each agent or policy file that does not read.
  """
  @spec status() :: String.t()
  def status do
    members = Fleet.list()
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

    header =
      [
        "wardrik #{Application.spec(:wardrik, :vsn)} on #{Nodes.display(node())}, up #{duration(uptime_ms)}"
        | cluster()
      ] ++ ["#{length(members)} #{agents(members)}"]

    rows =
      for member <- members,
          do:
            Enum.join(
              [
                "  #{member.id}",
                member.status,
                if(member.asleep, do: "asleep", else: Nodes.display(member.node))
                | spent(member.id) ++ next_run(member.id)
              ],
              "  "
            )

    broken = for {_path, {:error, message}} <- agent_files(), do: "  #{message}"
    unbuilt = for message <- definition_problems(), do: "  #{message}"

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
  spec, from `files` as `WardrikDaemon.Agents.files/0` answers them.
  """
  @spec declared([WardrikDaemon.Agents.file()]) ::
          %{Wardrik.AgentID.t() => {Path.t(), Wardrik.Agent.Spec.t()}}
  def declared(files \\ agent_files()) do
    for {path, {:ok, %Wardrik.Agent.Spec{} = spec}} <- files,
        into: %{},
        do: {spec.id, {path, spec}}
  end

  @doc """
  What the agent `key` has spent of each budget the spec its kept definition
  writes gives it, as its budgets say it; nothing where none is kept.
  """
  @spec spent(Wardrik.AgentID.t()) :: [String.t()]
  def spent(key) do
    with {:ok, definition} <- WardrikDaemon.Definition.of(key),
         {:ok, spec} <- WardrikDaemon.Agents.build(definition, key) do
      spent(spec, key)
    else
      {:error, _reason} -> []
    end
  end

  @doc "What the agent `key` has spent of each budget `spec` gives it, as its budgets say it."
  @spec spent(Wardrik.Agent.Spec.t() | nil, Wardrik.AgentID.t()) :: [String.t()]
  def spent(%Wardrik.Agent.Spec{hooks: hooks}, key) when is_list(hooks) do
    for %Wardrik.Hook{module: WardrikPolicy.Budget, value: budget} <- hooks,
        spent = WardrikPolicy.Budget.spending(budget, key),
        spent != nil,
        do: spent
  end

  def spent(_spec, _key), do: []

  @doc "How long until a schedule next asks the agent `key`, in milliseconds, or `nil` where none does."
  @spec next_in(Wardrik.AgentID.t()) :: non_neg_integer() | nil
  def next_in(key) do
    case WardrikSchedule.for_agent(key) do
      [] ->
        nil

      schedules ->
        next = schedules |> Enum.map(& &1.next_at) |> Enum.min(DateTime)
        max(DateTime.diff(next, DateTime.utc_now(), :millisecond), 0)
    end
  end

  defp next_run(key) do
    case next_in(key) do
      nil -> []
      ms -> ["next run in #{duration(ms)}"]
    end
  end

  @doc "The agent and policy files, as `WardrikDaemon.Agents.files/0` reads them, or none where it is not running."
  @spec agent_files() :: [WardrikDaemon.Agents.file()]
  def agent_files do
    if Process.whereis(WardrikDaemon.Agents), do: WardrikDaemon.Agents.files(), else: []
  end

  defp definition_problems do
    if Process.whereis(WardrikDaemon.Agents), do: WardrikDaemon.Agents.problems(), else: []
  end

  defp cluster do
    cond do
      not Cluster.configured?() ->
        []

      Cluster.named() == [] ->
        ["cluster of #{Cluster.size()}, found by DNS: " <> found(Cluster.members())]

      true ->
        {up, down} = Enum.split_with(Cluster.named(), &(&1 in Cluster.members()))

        [
          "cluster of #{Cluster.size()}: " <>
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
