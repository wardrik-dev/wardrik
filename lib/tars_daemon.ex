defmodule TarsDaemon do
  @moduledoc """
  The host a `tars` release runs beside core.

  The release names it in core's `:children`, so it starts once the fleet is
  up:

      config :tars, :children, [TarsDaemon]

  Starting, it reads `config.yaml` from the config directory into the settings
  each package reads (see `TarsDaemon.Config`), then starts what those
  settings call for:

    * `TarsMCP.Supervisor`, when a server is configured. Each command's stderr
      goes to `log/mcp.log` in the state directory.
    * `TarsOAuth.Supervisor`, when a provider is configured.
    * `TarsDaemon.Agents`, which runs the agents `agents/` declares.

  A `config.yaml` that does not read stops the boot, with the reason logged.

  `:config_dir` and `:state_dir` override `TarsDaemon.Config.config_dir/0`
  and `TarsDaemon.Config.state_dir/0`.

  ## From a shell

  The release's `bin/tars` drives it:

      tars serve     # in the foreground, logging to the terminal
      tars start     # in the background, logging to the state directory
      tars status    # what is running
      tars reload    # read agents/ and policies/ again
      tars parked    # what is waiting on a person
      tars approve KEY CALL
      tars deny KEY CALL [REASON]
      tars remote    # an IEx shell on the node
      tars logs      # follow the log
      tars stop
  """

  use Supervisor

  require Logger

  alias Tars.Fleet
  alias TarsDaemon.Config

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    config_dir = Keyword.get_lazy(opts, :config_dir, &Config.config_dir/0)
    state_dir = Keyword.get_lazy(opts, :state_dir, &Config.state_dir/0)

    case Config.read(Path.join(config_dir, "config.yaml")) do
      {:ok, settings} ->
        :ok = Config.apply(settings)
        Supervisor.start_link(__MODULE__, {config_dir, state_dir}, name: __MODULE__)

      {:error, message} ->
        Logger.error(message)
        {:error, {:config, message}}
    end
  end

  @impl true
  def init({config_dir, state_dir}) do
    children =
      mcp(Path.join([state_dir, "log", "mcp.log"])) ++
        oauth() ++
        [{TarsDaemon.Agents, dir: config_dir}]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp mcp(stderr) do
    if TarsMCP.configured?() do
      File.mkdir_p!(Path.dirname(stderr))
      [{TarsMCP.Supervisor, stderr: {:file, stderr}}]
    else
      []
    end
  end

  defp oauth do
    if TarsOAuth.Config.configured?(), do: [TarsOAuth.Supervisor], else: []
  end

  @doc """
  What this node is running, as `tars status` prints it: the node, how long
  it has been up, each agent in the fleet with what it is doing, and each agent
  or policy file that does not read.
  """
  @spec status() :: String.t()
  def status do
    members = Fleet.list()
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

    header = [
      "tars #{Application.spec(:tars, :vsn)} on #{node()}, up #{duration(uptime_ms)}",
      "#{length(members)} #{agents(members)}"
    ]

    files = agent_files()

    specs =
      for {_path, {:ok, %Tars.Agent.Spec{} = spec}} <- files,
          into: %{},
          do: {Tars.Agent.Spec.key(spec), spec}

    rows =
      for member <- members,
          do:
            Enum.join(
              [
                "  #{member.key}",
                member.status,
                member.node | spending(specs[member.key], member.key)
              ],
              "  "
            )

    broken =
      for {_path, {:error, message}} <- files,
          do: "  #{message}"

    Enum.join(header ++ rows ++ problems(broken), "\n")
  end

  defp spending(%Tars.Agent.Spec{policy: {TarsPolicy, policy}}, key) do
    case TarsPolicy.spending(policy, key) do
      nil -> []
      spent -> [spent]
    end
  end

  defp spending(_spec, _key), do: []

  defp agent_files do
    if Process.whereis(TarsDaemon.Agents), do: TarsDaemon.Agents.files(), else: []
  end

  defp problems([]), do: []
  defp problems([_one] = broken), do: ["", "1 file does not read:" | broken]
  defp problems(broken), do: ["", "#{length(broken)} files do not read:" | broken]

  defp agents([_member]), do: "agent"
  defp agents(_members), do: "agents"

  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  defp duration(ms), do: "#{div(ms, 3_600_000)}h #{div(rem(ms, 3_600_000), 60_000)}m"
end
