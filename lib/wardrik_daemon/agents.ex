defmodule WardrikDaemon.Agents do
  @moduledoc """
  Runs the agents `agents/` in the config directory declares, one per `*.md`
  file, under the policies `policies/` declares, one per `*.yaml` or `*.yml`
  file. See
  `WardrikDaemon.AgentFile` and `WardrikDaemon.PolicyFile` for what each says.

  It reads every file when it starts and again on `reload/0`, policies first,
  and puts each agent's `Wardrik.Agent.Spec` to the fleet with `Wardrik.Fleet.put/1`:
  an agent that is not running is started, and one that is takes what its file
  says now. An agent keeps its conversation either way. Each file's `notify`
  becomes the agent's route with `WardrikNotify.put_routes/1`.

  A file that does not read, or whose agent does not start, is reported by
  `files/0`, and by `wardrik status`, and every other file is read as if it were
  not there. An agent already running for it is left as it was, and an agent
  naming a policy that does not read does not read either. Removing a file
  stops nothing; `Wardrik.Fleet.forget/1` removes an agent and what it said.

  It is also the daemon's `WardrikHTTP.Definition`. `put/2` reads a definition
  sent to the HTTP API with `WardrikDaemon.AgentFile.definition/3`, under the
  policies it last read, and keeps none; an agent defined that way has no
  file, so `files/0` and `reload/0` leave it out. A key an agent file
  declares belongs to the file: `put/2` and `delete/1` refuse it with a
  conflict.
  """

  @behaviour WardrikHTTP.Definition

  use GenServer

  require Logger

  alias Wardrik.Agent.Spec
  alias Wardrik.Fleet
  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.PolicyFile

  @typedoc "What became of one file: the spec or policy it writes, or why it writes neither."
  @type file() :: {Path.t(), {:ok, Spec.t() | WardrikPolicy.t()} | {:error, String.t()}}

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

  @doc """
  The spec a definition sent to the HTTP API writes for the agent under
  `key`, or a conflict where an agent file declares it.
  """
  @impl WardrikHTTP.Definition
  def put(key, definition) do
    case GenServer.call(__MODULE__, {:owner, key}) do
      {:file, path} -> declared(key, path)
      {:api, policies} -> AgentFile.definition(key, definition, policies)
    end
  end

  @doc """
  Keeps no definitions, so `{:error, :not_found}`, or a conflict where an
  agent file declares `key`.
  """
  @impl WardrikHTTP.Definition
  def delete(key) do
    case GenServer.call(__MODULE__, {:owner, key}) do
      {:file, path} -> declared(key, path)
      {:api, _policies} -> {:error, :not_found}
    end
  end

  defp declared(key, path),
    do:
      {:error, :conflict, "#{key} is declared by agents/#{Path.basename(path)}; change the file"}

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

  def handle_call({:owner, key}, _from, state) do
    file =
      Enum.find_value(state.files, fn
        {path, {:ok, %Spec{} = spec}} -> if Spec.key(spec) == key, do: path
        _other -> nil
      end)

    policies =
      for {_path, {:ok, %WardrikPolicy{} = policy}} <- state.files,
          into: %{},
          do: {policy.name, policy}

    {:reply, if(file, do: {:file, file}, else: {:api, policies}), state}
  end

  @doc """
  What the policy and agent files under `dir` read into, without starting
  anything: each policy file's policy, and each agent file's spec with where
  its notices go, or the message saying why it does not read.
  """
  @spec read_files(Path.t()) ::
          {[{Path.t(), {:ok, WardrikPolicy.t()} | {:error, String.t()}}],
           [{Path.t(), {:ok, Spec.t(), WardrikNotify.Route.t() | nil} | {:error, String.t()}}]}
  def read_files(dir) do
    policy_files = dir |> read("policies/*.{yaml,yml}", &PolicyFile.read/1) |> once_each()
    policies = for {_path, {:ok, policy}} <- policy_files, into: %{}, do: {policy.name, policy}
    {policy_files, read(dir, "agents/*.md", &AgentFile.load(&1, policies))}
  end

  defp load(%{dir: dir} = state) do
    {policy_files, read} = read_files(dir)
    loaded = for {path, result} <- read, do: {path, contained(path, fn _path -> put(result) end)}
    agent_files = for {path, result} <- loaded, do: {path, spec_only(result)}

    :ok =
      WardrikNotify.put_routes(
        for {_path, {:ok, spec, %WardrikNotify.Route{} = route}} <- loaded,
            into: %{},
            do: {Spec.key(spec), route}
      )

    files = policy_files ++ agent_files
    for {_path, {:error, message}} <- files, do: Logger.error(message)

    %{state | files: files}
  end

  # careful.yaml and careful.yml would both be the policy careful; the first by
  # name is read, and the other reported.
  defp once_each(files) do
    {files, _seen} =
      Enum.map_reduce(files, %{}, fn
        {path, {:ok, %{name: name}}} = file, seen ->
          case Map.fetch(seen, name) do
            {:ok, first} ->
              {{path, {:error, "#{path}: policy #{name} is already #{Path.basename(first)}"}},
               seen}

            :error ->
              {file, Map.put(seen, name, path)}
          end

        file, seen ->
          {file, seen}
      end)

    files
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
