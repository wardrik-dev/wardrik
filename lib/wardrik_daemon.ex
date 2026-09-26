defmodule WardrikDaemon do
  @moduledoc """
  The host a `wardrik` release runs beside core.

  The release names it in core's `:children`, after `WardrikPolicy.Supervisor`,
  which keeps the budgets its agents' policies set, and `WardrikHTTP.Workers`,
  the tool workers connected to the cluster, so all three start once the
  fleet is up, and `WardrikDaemon.Cluster` in core's `:cluster`, which starts
  before the fleet:

      config :wardrik, :cluster, [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]
      config :wardrik, :children, [WardrikPolicy.Supervisor, WardrikHTTP.Workers, WardrikDaemon]

  Starting, it reads `config.yaml`, or `config.yml`, from the config directory
  into the settings
  each package reads (see `WardrikDaemon.Config`), then starts what those
  settings call for:

    * `WardrikMCP.Supervisor`, when a server is configured. Each command's stderr
      goes to `log/mcp.log` in the state directory.
    * `WardrikOAuth.Supervisor`, when a provider is configured.
    * `WardrikNotify.Supervisor`, when a notify target is configured.
    * `WardrikDaemon.Agents`, which runs the agents `agents/` declares.
    * `WardrikDaemon.SSH`, which serves the TUI over SSH, where `ssh/authorized_keys`
      in the config directory lets anyone in.
    * `WardrikHTTP.Listener`, which serves the HTTP API on loopback, to callers
      holding a token that `wardrik token create` made, and defines agents with
      `WardrikDaemon.Agents`.

  A `config.yaml` that does not read stops the boot, with the reason logged.

  `:config_dir`, `:state_dir` and `:data_dir` override
  `WardrikDaemon.Config.config_dir/0`, `WardrikDaemon.Config.state_dir/0` and
  `WardrikDaemon.Config.data_dir/0`.

  ## From a shell

  The release's `bin/wardrik` drives it:

      wardrik serve     # in the foreground, logging to the terminal
      wardrik start     # in the background, logging to the state directory
      wardrik status    # what is running
      wardrik reload    # read agents/ and policies/ again
      wardrik parked    # what is waiting on a person
      wardrik schedules # when each schedule runs next, and how it last ran
      wardrik approve KEY CALL
      wardrik deny KEY CALL [REASON]
      wardrik token create NAME --scope PREFIX   # a token for the HTTP API
      wardrik attach    # the TUI, over SSH
      wardrik remote    # an IEx shell on the node
      wardrik logs      # follow the log
      wardrik stop
  """

  use Supervisor

  require Logger

  alias Wardrik.Fleet
  alias WardrikDaemon.Cluster
  alias WardrikDaemon.Config

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    config_dir = Keyword.get_lazy(opts, :config_dir, &Config.config_dir/0)
    state_dir = Keyword.get_lazy(opts, :state_dir, &Config.state_dir/0)
    data_dir = Keyword.get_lazy(opts, :data_dir, &Config.data_dir/0)

    with {:ok, file} <- Config.file(config_dir),
         {:ok, settings} <- Config.read(file) do
      :ok = Config.apply(settings)
      Supervisor.start_link(__MODULE__, {config_dir, state_dir, data_dir}, name: __MODULE__)
    else
      {:error, message} ->
        Logger.error(message)
        {:error, {:config, message}}
    end
  end

  @impl true
  def init({config_dir, state_dir, data_dir}) do
    children =
      mcp(Path.join([state_dir, "log", "mcp.log"])) ++
        oauth() ++
        notify() ++
        [{WardrikDaemon.Agents, dir: config_dir}] ++
        WardrikDaemon.SSH.children(config_dir, data_dir) ++
        [{WardrikHTTP.Listener, definition: WardrikDaemon.Agents}]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp mcp(stderr) do
    if WardrikMCP.configured?() do
      File.mkdir_p!(Path.dirname(stderr))
      [{WardrikMCP.Supervisor, stderr: {:file, stderr}}]
    else
      []
    end
  end

  defp oauth do
    if WardrikOAuth.Config.configured?(), do: [WardrikOAuth.Supervisor], else: []
  end

  defp notify do
    if WardrikNotify.configured?(), do: [WardrikNotify.Supervisor], else: []
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
        "wardrik #{Application.spec(:wardrik, :vsn)} on #{Cluster.display(node())}, up #{duration(uptime_ms)}"
        | cluster()
      ] ++ ["#{length(members)} #{agents(members)}"]

    files = agent_files()

    specs =
      for {_path, {:ok, %Wardrik.Agent.Spec{} = spec}} <- files,
          into: %{},
          do: {Wardrik.Agent.Spec.key(spec), spec}

    rows =
      for member <- members,
          do:
            Enum.join(
              [
                "  #{member.key}",
                member.status,
                Cluster.display(member.node)
                | spending(specs[member.key], member.key) ++ next_run(member.key)
              ],
              "  "
            )

    broken =
      for {_path, {:error, message}} <- files,
          do: "  #{message}"

    Enum.join(header ++ rows ++ problems(broken), "\n")
  end

  defp spending(%Wardrik.Agent.Spec{hooks: hooks}, key) when is_list(hooks) do
    for %Wardrik.Hook{module: WardrikPolicy.Budget, value: budget} <- hooks,
        spent = WardrikPolicy.Budget.spending(budget, key),
        spent != nil,
        do: spent
  end

  defp spending(_spec, _key), do: []

  defp next_run(key) do
    case Wardrik.Schedule.for_agent(key) do
      [] ->
        []

      schedules ->
        next = schedules |> Enum.map(& &1.next_at) |> Enum.min(DateTime)
        ms = max(DateTime.diff(next, DateTime.utc_now(), :millisecond), 0)
        ["next run in #{duration(ms)}"]
    end
  end

  defp agent_files do
    if Process.whereis(WardrikDaemon.Agents), do: WardrikDaemon.Agents.files(), else: []
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
  defp found(nodes), do: Enum.map_join(nodes, ", ", &Cluster.display/1) <> " connected"

  defp nodes(nodes, prefix \\ "", state)
  defp nodes([], _prefix, _state), do: ""

  defp nodes(nodes, prefix, state),
    do: prefix <> Enum.map_join(nodes, ", ", &Cluster.display/1) <> " " <> state

  defp problems([]), do: []
  defp problems([_one] = broken), do: ["", "1 file does not read:" | broken]
  defp problems(broken), do: ["", "#{length(broken)} files do not read:" | broken]

  defp agents([_member]), do: "agent"
  defp agents(_members), do: "agents"

  @doc false
  @spec duration(non_neg_integer()) :: String.t()
  def duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  def duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  def duration(ms), do: "#{div(ms, 3_600_000)}h #{div(rem(ms, 3_600_000), 60_000)}m"
end
