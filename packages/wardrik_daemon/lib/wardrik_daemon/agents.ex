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
  naming a policy that does not read does not read either.

  ## Agents the files no longer declare

  Each node keeps its own inventory in the store: the keys its agent files
  declare, and the name of the file each came from. A key its inventory held
  that no file declares any more, because its file was removed or now names
  another agent, is retired once no other node connected to it declares it
  either: the agent stops and its schedules are cleared, and it keeps its
  conversation, so a file that declares it again brings it back as it was.
  `Wardrik.Fleet.forget/1`, or `wardrik agent rm`, removes it for good. A
  file that does not read keeps its keys in the inventory, so its agent is
  left as it was. An agent the HTTP API defined is in no inventory, and
  reading the files never touches it.

  It is also the daemon's `WardrikHTTP.Definition`. `put/2` reads a definition
  sent to the HTTP API with `WardrikDaemon.AgentFile.definition/3`, under the
  policies it last read, and keeps none; an agent defined that way has no
  file, so `files/0` and `reload/0` leave it out. A key an agent file
  declares, here or on any node connected to this one, belongs to the file:
  `put/2`, `delete/1` and `editable/1` refuse it with a conflict, so the API
  changes neither it nor its schedules.

  ## Defaults

  `config.yaml`'s `defaults` is what an agent is given where nothing else
  says, read as a definition over the HTTP API is. `options/1` answers what
  an agent starts with, its file's or the defaults', for a surface that
  starts one under a key no file declares, as the TUI does; `wardrik agent
  spawn` writes a file from them.
  """

  @behaviour WardrikHTTP.Definition

  use GenServer

  require Logger

  alias Wardrik.Agent.Spec
  alias Wardrik.Fleet
  alias Wardrik.Schedule
  alias Wardrik.Store
  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.PolicyFile

  @inventory :declared

  @typedoc "What became of one file: the spec or policy it writes, or why it writes neither."
  @type file() :: {Path.t(), {:ok, Spec.t() | WardrikPolicy.t()} | {:error, String.t()}}

  @doc """
  Starts it, reading the files under `:dir`. `:nodes` gives the other nodes
  whose inventories count, `Node.list/0` unless given.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    state = %{dir: Keyword.fetch!(opts, :dir), nodes: Keyword.get(opts, :nodes, &Node.list/0)}
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
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

  @doc "The config directory the files are read from."
  @spec dir() :: Path.t()
  def dir, do: GenServer.call(__MODULE__, :dir)

  @doc "`config.yaml`'s `defaults`, as the file writes them, or none."
  @spec defaults() :: map()
  def defaults,
    do: :wardrik_daemon |> Application.get_env(__MODULE__, []) |> Keyword.get(:defaults, %{})

  @doc """
  The options the agent `key` starts with, as `Wardrik.Fleet.spawn/2` takes
  them: what its file says, or `defaults/0` where no file declares it.
  """
  @spec options(Wardrik.AgentID.t()) :: {:ok, keyword()} | {:error, String.t()}
  def options(key) do
    spec =
      case GenServer.call(__MODULE__, {:owner, key}) do
        {:file, _path, %Spec{} = spec} -> {:ok, spec}
        {:file, elsewhere, nil} -> conflict(declared(key, elsewhere))
        {:api, policies} -> AgentFile.definition(key, defaults(), policies)
      end

    with {:ok, spec} <- spec, do: {:ok, Spec.options(spec)}
  end

  @doc """
  The spec a definition sent to the HTTP API writes for the agent `key`, or
  a conflict where an agent file declares it.
  """
  @impl WardrikHTTP.Definition
  def put(key, definition) do
    case GenServer.call(__MODULE__, {:owner, key}) do
      {:file, path, _spec} -> declared(key, path)
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
      {:file, path, _spec} -> declared(key, path)
      {:api, _policies} -> {:error, :not_found}
    end
  end

  @doc "`:ok` where the HTTP API may change the agent `key`, or a conflict where a file declares it."
  @impl WardrikHTTP.Definition
  def editable(key) do
    case GenServer.call(__MODULE__, {:owner, key}) do
      {:file, path, _spec} -> declared(key, path)
      {:api, _policies} -> :ok
    end
  end

  defp conflict({:error, :conflict, message}), do: {:error, message}

  defp declared(key, {path, node}),
    do:
      {:error, :conflict,
       "#{key} is declared by agents/#{Path.basename(path)} on #{node}; change the file"}

  defp declared(key, path),
    do:
      {:error, :conflict, "#{key} is declared by agents/#{Path.basename(path)}; change the file"}

  @impl true
  def init(state), do: {:ok, Map.put(state, :files, []), {:continue, :load}}

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_call(:reload, _from, state) do
    state = load(state)
    {:reply, state.files, state}
  end

  def handle_call(:files, _from, state), do: {:reply, state.files, state}
  def handle_call(:dir, _from, state), do: {:reply, state.dir, state}

  def handle_call({:owner, key}, _from, state) do
    file =
      Enum.find_value(state.files, fn
        {path, {:ok, %Spec{} = spec}} -> if spec.id == key, do: {:file, path, spec}
        _other -> nil
      end)

    policies =
      for {_path, {:ok, %WardrikPolicy{} = policy}} <- state.files,
          into: %{},
          do: {policy.name, policy}

    {:reply, file || elsewhere(state, key) || {:api, policies}, state}
  end

  # The file another node connected to this one declares `key` in, with the
  # node, as its inventory has it. This node has not read it, so it has no
  # spec of it.
  defp elsewhere(state, key) do
    Enum.find_value(state.nodes.(), fn node ->
      case Map.fetch(Store.get(@inventory, inventory(node)) || %{}, to_string(key)) do
        {:ok, path} -> {:file, {path, node}, nil}
        :error -> nil
      end
    end)
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
    prune(state, agent_files)

    :ok =
      WardrikNotify.put_routes(
        for {_path, {:ok, spec, %WardrikNotify.Route{} = route}} <- loaded,
            into: %{},
            do: {spec.id, route}
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

  # The keys the files declare now, and those of files that do not read,
  # become this node's inventory. A key it held before that it holds no
  # longer, and that no connected node's inventory holds, is retired.
  defp prune(state, agent_files) do
    named = for {path, result} <- agent_files, do: {Path.basename(path), result}
    unread = for {name, {:error, _message}} <- named, into: MapSet.new(), do: name
    declared = for {name, {:ok, spec}} <- named, into: %{}, do: {to_string(spec.id), name}

    previous = Store.get(@inventory, inventory(node())) || %{}
    kept = Map.filter(previous, fn {_key, path} -> MapSet.member?(unread, path) end)
    inventory = Map.merge(kept, declared)
    {:ok, _vsn} = Store.put(@inventory, inventory(node()), inventory)

    for text <- Map.keys(previous) -- Map.keys(inventory),
        key = Wardrik.AgentID.parse!(text),
        elsewhere(state, key) == nil,
        do: retire(key)
  end

  defp inventory(node), do: "agents/#{node}"

  defp retire(key) do
    :ok = Schedule.sync(key, [])

    case Fleet.stop(key) do
      :ok -> :ok
      {:error, :noproc} -> :ok
    end
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
      {:error, reason} -> {:error, "#{spec.id} did not start: #{inspect(reason)}"}
    end
  end

  defp put({:error, _message} = error), do: error
end
