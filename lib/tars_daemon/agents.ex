defmodule TarsDaemon.Agents do
  @moduledoc """
  Runs the agents `agents/` in the config directory declares, one per `*.md`
  file, under the policies `policies/` declares, one per `*.yaml` file. See
  `TarsDaemon.AgentFile` and `TarsDaemon.PolicyFile` for what each says.

  It reads every file when it starts and again on `reload/0`, policies first,
  and puts each agent's `Tars.Agent.Spec` to the fleet with `Tars.Fleet.put/1`:
  an agent that is not running is started, and one that is takes what its file
  says now. An agent keeps its conversation either way. Each file's `notify`
  becomes the agent's route with `TarsNotify.put_routes/1`.

  A file that does not read, or whose agent does not start, is reported by
  `files/0`, and by `tars status`, and every other file is read as if it were
  not there. An agent already running for it is left as it was, and an agent
  naming a policy that does not read does not read either. Removing a file
  stops nothing; `Tars.Fleet.forget/1` removes an agent and what it said.
  """

  use GenServer

  require Logger

  alias Tars.Agent.Spec
  alias Tars.Fleet
  alias TarsDaemon.AgentFile
  alias TarsDaemon.PolicyFile

  @typedoc "What became of one file: the spec or policy it writes, or why it writes neither."
  @type file() :: {Path.t(), {:ok, Spec.t() | TarsPolicy.t()} | {:error, String.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :dir), name: __MODULE__)
  end

  @doc "Reads every file again and brings the fleet to what they say."
  @spec reload() :: [file()]
  def reload, do: GenServer.call(__MODULE__, :reload, :timer.minutes(1))

  @doc """
  What became of each file the last time they were read: the policies, then
  the agents, each in the order of their names.
  """
  @spec files() :: [file()]
  def files, do: GenServer.call(__MODULE__, :files)

  @impl true
  def init(dir), do: {:ok, %{dir: dir, files: []}, {:continue, :load}}

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_call(:reload, _from, state) do
    state = load(state)
    {:reply, state.files, state}
  end

  def handle_call(:files, _from, state), do: {:reply, state.files, state}

  defp load(%{dir: dir} = state) do
    policy_files = read(dir, "policies/*.yaml", &PolicyFile.read/1)
    policies = for {_path, {:ok, policy}} <- policy_files, into: %{}, do: {policy.name, policy}

    loaded = read(dir, "agents/*.md", &(&1 |> AgentFile.load(policies) |> put()))
    agent_files = for {path, result} <- loaded, do: {path, spec_only(result)}

    :ok =
      TarsNotify.put_routes(
        for {_path, {:ok, spec, %TarsNotify.Route{} = route}} <- loaded,
            into: %{},
            do: {Spec.key(spec), route}
      )

    files = policy_files ++ agent_files
    for {_path, {:error, message}} <- files, do: Logger.error(message)

    %{state | files: files}
  end

  defp spec_only({:ok, spec, _route}), do: {:ok, spec}
  defp spec_only(other), do: other

  defp read(dir, pattern, read) do
    dir
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{&1, contained(&1, read)})
  end

  defp contained(path, read) do
    read.(path)
  catch
    kind, reason ->
      {:error, "#{path}: " <> String.trim_leading(Exception.format_banner(kind, reason), "** ")}
  end

  defp put({:ok, spec, route}) do
    case Fleet.put(spec) do
      {:ok, _pid} -> {:ok, spec, route}
      {:error, reason} -> {:error, "#{Spec.key(spec)} did not start: #{inspect(reason)}"}
    end
  end

  defp put({:error, _message} = error), do: error
end
