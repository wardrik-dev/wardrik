defmodule WardrikDaemon.Agents do
  @moduledoc """
  Runs the agents `agents/` in the config directory declares, one per `*.md`
  file, under the policies `policies/` declares, one per `*.yaml` or `*.yml`
  file. See
  `WardrikDaemon.AgentFile` and `WardrikDaemon.PolicyFile` for what each says.

  It reads every file when it starts and again on `reload/0`, policies first,
  and puts each agent's `Wardrik.Agent.Spec` to the fleet with `Wardrik.Fleet.put/1`:
  an agent that is not running is started, and one that is takes what its file
  says now. An agent keeps its conversation either way. Each file's
  `WardrikDaemon.Definition` is kept, and its `notify` becomes the agent's
  route with `WardrikNotify.put_routes/1`.

  A definition's `triggers` are its agent's triggers, so each is brought to
  what a definition lists as it is kept, with `WardrikTrigger.sync/2`, and
  cleared as it is deleted.

  A file that does not read, or whose agent does not start, is reported by
  `files/0`, and by `wardrik status`, and every other file is read as if it were
  not there. An agent already running for it is left as it was, and an agent
  naming a policy that does not read does not read either.

  ## Agents the files no longer declare

  Each node keeps its own inventory in the store: the keys its agent files
  declare, and the name of the file each came from. A key its inventory held
  that no file declares any more, because its file was removed or now names
  another agent, is retired once no other node connected to it declares it
  either: the agent stops, its triggers are cleared and its definition
  forgotten, and it keeps its conversation, so a file that declares it again
  brings it back as it was.
  `Wardrik.Fleet.forget/1`, or `wardrik agent rm`, removes it for good. A
  file that does not read keeps its keys in the inventory, so its agent is
  left as it was. An agent the HTTP API defined is in no inventory, and
  reading the files never touches it.

  It is also the daemon's `Wardrik.Definition`. `put/3` reads a definition
  sent to the HTTP API with `WardrikDaemon.AgentFile.define/3`, under the
  policies it last read, and keeps it with the grant of the token that sent
  it; `get/1` answers it, `delete/1` forgets it, and `put_trigger/3` and
  `delete_trigger/2` change one of its triggers. A key an agent file
  declares, here or on any node connected to this one, belongs to the file:
  each of them refuses it with a conflict, so the API changes neither it nor
  its triggers.

  ## Reading what was read

  Files are read in its process, one reading at a time. What each reading
  comes to is published to an ETS table the process owns, so nothing of it
  outlives the process, and `files/0`, `dir/0`, `problems/0`, the policies a
  spec is built under, and whether a file declares a key are read from it
  in the caller: none of them waits behind a reading under way. Until the
  first reading is done they wait for it.

  ## Agents a kept definition writes

  `reload/0` brings every running agent the API defined, its conversations,
  and the conversations of an agent a file that read declares, to what their
  definitions say under the policies read then and the ceiling of the token
  that sent them, and `problems/0` says why one does not build. Those of a
  file that does not read are left as they were, as its agent is. It forgets the definitions the
  API sent for agents the store no longer holds, which something other than
  the API removed, as the TUI does.

  ## Defaults

  `config.yaml`'s `defaults` is what an agent is given where nothing else
  says, read as a definition over the HTTP API is. `options/1` answers what
  an agent starts with, for a surface that starts one, as the TUI does: what
  the definition it runs on writes, or the defaults' where none is kept.
  `wardrik agent spawn` writes a file from them.
  """

  @behaviour Wardrik.Definition

  use GenServer

  require Logger

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.Fleet
  alias Wardrik.Grant
  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.Definition
  alias WardrikDaemon.PolicyFile

  @inventory :declared
  @table __MODULE__

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
  def files, do: loaded().files

  @doc "The config directory the files are read from."
  @spec dir() :: Path.t()
  def dir, do: :ets.lookup_element(@table, :dir, 2)

  @doc "`config.yaml`'s `defaults`, as the file writes them, or none."
  @spec defaults() :: map()
  def defaults,
    do: :wardrik_daemon |> Application.get_env(__MODULE__, []) |> Keyword.get(:defaults, %{})

  @doc """
  The agents offered in the rooms of the channel `channel`, as
  `WardrikChannel.Context` asks: those whose definitions name the channel,
  of the orgs `config.yaml` has the channel serve, each with its
  `description`. Sorted by ID.
  """
  @spec offered(String.t()) :: [WardrikChannel.Offer.t()]
  def offered(channel) when is_binary(channel) do
    orgs = channel_setting(:orgs, channel, [])

    for %Definition{id: id, fields: fields} <- Definition.all(),
        channel in AgentFile.channels(fields),
        orgs == :all or id.org in orgs do
      %WardrikChannel.Offer{agent: id, description: fields["description"]}
    end
    |> Enum.sort_by(&to_string(&1.agent))
  end

  @doc """
  Whether someone in a room of the channel `channel` may create an agent to
  answer there: where the channel's `create` is not `false`, and
  `config.yaml`'s `defaults`, which such an agent starts from, name a policy
  its calls are held to.
  """
  @spec creatable?(String.t()) :: boolean()
  def creatable?(channel) when is_binary(channel),
    do: channel_setting(:creates, channel, true) and is_map_key(defaults(), "policy")

  @doc """
  Creates an agent for the room `room` of the channel `channel`, as `by`
  asked: named after the room, in the channel's org, from `config.yaml`'s
  `defaults`, offered in the channel. It is kept as a definition the HTTP API
  sent is, and recorded in `Wardrik.Audit` as defined by `by`.
  """
  @spec create(String.t(), String.t(), Wardrik.Principal.t() | nil) ::
          {:ok, WardrikChannel.Offer.t()} | {:error, String.t()}
  def create(channel, room, by) when is_binary(channel) and is_binary(room) do
    description = "Answers in ##{room}."
    fields = Map.merge(defaults(), %{"channels" => [channel], "description" => description})

    with :ok <- creates(channel),
         {:ok, id} <- created_id(room, channel),
         :ok <- unkept(id, channel),
         {:ok, spec} <- put(id, fields, nil),
         {:ok, _pid} <- Fleet.put(spec) do
      :ok = Wardrik.Audit.record({:agent_defined, id}, by)
      {:ok, %WardrikChannel.Offer{agent: id, description: description}}
    else
      {:error, :conflict, message} -> {:error, message}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "The agent did not start: #{inspect(reason)}"}
    end
  end

  @doc """
  Starts `agent`, which answers in a thread of the channel `channel`, on the
  spec its definition writes, where it is not running.
  """
  @spec start(String.t(), AgentID.t()) :: {:ok, pid()} | {:error, String.t()}
  def start(channel, %AgentID{} = agent) when is_binary(channel) do
    with {:ok, options} <- options(agent) do
      case Fleet.spawn(agent, options) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, "#{agent} did not start: #{inspect(reason)}"}
      end
    end
  end

  @doc "Who may answer what an agent asks in the channel `channel`'s threads."
  @spec approvers(String.t()) :: [String.t()]
  def approvers(channel) when is_binary(channel), do: channel_setting(:approvers, channel, [])

  defp creates(channel) do
    if creatable?(channel),
      do: :ok,
      else: {:error, "Agents are not created from here; whoever runs Wardrik can offer one."}
  end

  # An agent's name, from the room's, in the channel's own org.
  defp created_id(room, channel) do
    name = room |> String.downcase() |> String.replace(~r/[^a-z0-9_-]+/u, "-") |> String.trim("-")

    org =
      case channel_setting(:orgs, channel, :all) do
        [org | _] -> org
        _every -> WardrikDaemon.Config.org()
      end

    case AgentID.new(name, org: org) do
      {:ok, id} -> {:ok, id}
      {:error, _message} -> {:error, "#{inspect(room)} makes no agent's name."}
    end
  end

  defp unkept(id, channel) do
    case Definition.get(id) do
      {:error, :not_found} ->
        :ok

      {:ok, _definition} ->
        {:error,
         "#{id} is there already. Whoever runs Wardrik can offer it here by adding " <>
           "`channels: [#{channel}]` to it."}
    end
  end

  # What config.yaml says of the channel `channel` under `key`.
  defp channel_setting(key, channel, default) do
    settings = WardrikChannel |> WardrikDaemon.Config.settings() |> Keyword.get(key, [])

    case Enum.find(settings, fn {name, _value} -> Atom.to_string(name) == channel end) do
      {_name, value} -> value
      nil -> default
    end
  end

  @doc """
  The options the agent `key` starts with, as `Wardrik.Fleet.spawn/2` takes
  them: those of `spec/1`.
  """
  @spec options(AgentID.t()) :: {:ok, keyword()} | {:error, String.t()}
  def options(key) do
    with {:ok, spec} <- spec(key), do: {:ok, Spec.options(spec)}
  end

  @doc """
  The spec the agent `key` runs on: `build/2`'s, from the definition it runs
  on, as `WardrikDaemon.Definition.of/1` finds it, or from `defaults/0` where
  none is kept.
  """
  @spec spec(AgentID.t()) :: {:ok, Spec.t()} | {:error, String.t()}
  def spec(key) do
    # Asked first, so the files have been read once before the store is.
    policies = policies()

    definition =
      case Definition.of(key) do
        {:ok, definition} ->
          {:ok, definition}

        {:error, :not_found} ->
          AgentFile.define(AgentID.put_external_id(key, nil), defaults(), nil)
      end

    with {:ok, definition} <- definition, do: build(definition, key, policies)
  end

  @doc """
  The spec the definition kept for `key` writes now, for it or the agent it
  is a conversation of, or `:none` where none is kept or it does not build.
  The fleet asks it as an agent wakes, so a definition changed while the
  agent slept is the one it wakes with; see `Wardrik.Fleet`.
  """
  @spec current(AgentID.t()) :: {:ok, Spec.t()} | :none
  def current(key) do
    with {:ok, definition} <- Definition.of(key),
         {:ok, spec} <- build(definition, key) do
      {:ok, spec}
    else
      _none -> :none
    end
  end

  @doc """
  The spec `definition` writes for the agent `key`, its own or one of its
  conversations, under the policies last read, and under the ceiling of the
  token that sent it where one did.
  """
  @spec build(Definition.t(), AgentID.t()) :: {:ok, Spec.t()} | {:error, String.t()}
  def build(%Definition{} = definition, key), do: build(definition, key, policies())

  defp build(definition, key, policies) do
    with {:ok, spec, _route} <- AgentFile.spec(definition, key, policies),
         do: {:ok, held(spec, definition.source)}
  end

  defp held(spec, {:api, %Grant{} = grant}), do: %{spec | hooks: Grant.held(grant, spec.hooks)}
  defp held(spec, _source), do: spec

  defp policies do
    if :ets.whereis(@table) == :undefined, do: %{}, else: loaded().policies
  end

  # Published at the end of each reading. Before the first one there is
  # nothing to read, so the process is asked, and answers once it is done.
  defp loaded do
    case :ets.lookup(@table, :loaded) do
      [{:loaded, loaded}] -> loaded
      [] -> GenServer.call(__MODULE__, :loaded, :timer.minutes(1))
    end
  end

  @doc """
  The spec a definition sent to the HTTP API writes for the agent `key`, sent
  by a token holding `grant`, which it keeps; or a conflict where an agent
  file declares it.
  """
  @impl Wardrik.Definition
  def put(key, fields, grant) do
    case owner(key) do
      {:file, path, _spec} ->
        declared(key, path)

      {:api, policies} ->
        with {:ok, definition} <- AgentFile.define(key, fields, grant),
             {:ok, spec, _route} <- AgentFile.spec(definition, key, policies) do
          :ok = keep(definition)
          {:ok, spec}
        end
    end
  end

  @doc "The definition kept for the agent `key`, as the HTTP API writes one."
  @impl Wardrik.Definition
  def get(key) do
    with {:ok, definition} <- Definition.get(key), do: {:ok, AgentFile.fields(definition)}
  end

  @doc """
  Forgets the definition the HTTP API sent for the agent `key`:
  `{:error, :not_found}` where none was kept, or a conflict where an agent
  file declares `key`.
  """
  @impl Wardrik.Definition
  def delete(key) do
    case owner(key) do
      {:file, path, _spec} ->
        declared(key, path)

      {:api, _policies} ->
        with {:ok, _definition} <- Definition.get(key), do: drop(key)
    end
  end

  @doc """
  Sets the trigger `name` in the definition the HTTP API sent for the agent
  `key`, from `fields` as `WardrikDaemon.AgentFile.put_trigger/3` reads
  them, and brings the agent's triggers to it: whether it was added or
  changed, and the trigger as `WardrikTrigger.encode/1` writes it.
  `{:error, :not_found}` where no definition is kept, or a conflict where an
  agent file declares `key`.
  """
  @impl Wardrik.Definition
  def put_trigger(key, name, fields) do
    with {:ok, definition} <- defined(key),
         {:ok, definition, status, trigger} <- AgentFile.put_trigger(definition, name, fields) do
      :ok = keep(definition)
      {:ok, status, WardrikTrigger.encode(trigger)}
    end
  end

  @doc """
  Deletes the trigger `name` from the definition the HTTP API sent for the
  agent `key`, and stops it: `{:error, :not_found}` where neither is kept, or
  a conflict where an agent file declares `key`.
  """
  @impl Wardrik.Definition
  def delete_trigger(key, name) do
    with {:ok, definition} <- defined(key),
         {:ok, definition} <- AgentFile.delete_trigger(definition, name),
         do: keep(definition)
  end

  defp defined(key) do
    with :ok <- editable(key), do: Definition.get(key)
  end

  @doc "`:ok` where the HTTP API may change the agent `key`, or a conflict where a file declares it."
  @spec editable(AgentID.t()) :: :ok | {:error, :conflict, String.t()}
  def editable(key) do
    case owner(key) do
      {:file, path, _spec} -> declared(key, path)
      {:api, _policies} -> :ok
    end
  end

  @doc """
  Deletes the definition kept for the agent `key`, and the triggers it
  lists, as `wardrik agent rm` does once it has forgotten the agent.
  """
  @spec drop(AgentID.t()) :: :ok
  def drop(key) do
    :ok = WardrikTrigger.sync(key, [])
    Definition.delete(key)
  end

  # A trigger starts only once the definition listing it is kept.
  defp keep(definition) do
    :ok = Definition.put(definition)
    WardrikTrigger.sync(definition.id, AgentFile.triggers(definition))
  end

  @doc """
  Why each agent `reload/0` last built again from a kept definition did not
  build, a message each.
  """
  @spec problems() :: [String.t()]
  def problems, do: loaded().problems

  @doc """
  The route of each agent a file routes, as the last read of the files put
  them with `WardrikNotify.put_routes/1`, and none before the first. Read from
  a table rather than asked of the process, so `WardrikNotify` can ask while a
  read is putting them to it.
  """
  @spec routes() :: %{AgentID.t() => WardrikNotify.Route.t()}
  def routes do
    case :ets.lookup(@table, :routes) do
      [{:routes, routes}] -> routes
      [] -> %{}
    end
  end

  defp declared(key, {path, node}),
    do:
      {:error, :conflict,
       "#{key} is declared by agents/#{Path.basename(path)} on #{node}; change the file"}

  defp declared(key, path),
    do:
      {:error, :conflict, "#{key} is declared by agents/#{Path.basename(path)}; change the file"}

  # Whether a file declares `key`, here with its spec or on another node, or
  # the policies a definition the API sends for it is read under.
  defp owner(key) do
    %{files: files, policies: policies} = loaded()

    file =
      Enum.find_value(files, fn
        {path, {:ok, %Spec{} = spec}} -> if spec.id == key, do: {:file, path, spec}
        _other -> nil
      end)

    file || elsewhere(:ets.lookup_element(@table, :nodes, 2), key) || {:api, policies}
  end

  @impl true
  def init(state) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    true = :ets.insert(@table, [{:dir, state.dir}, {:nodes, state.nodes}])
    {:ok, Map.merge(state, %{files: [], problems: []}), {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_call(:reload, _from, state) do
    state = load(state)
    {:reply, state.files, state}
  end

  def handle_call(:loaded, _from, state), do: {:reply, published(state), state}

  defp policies(state) do
    for {_path, {:ok, %WardrikPolicy{} = policy}} <- state.files,
        into: %{},
        do: {policy.name, policy}
  end

  defp published(state),
    do: %{files: state.files, policies: policies(state), problems: state.problems}

  # The file another node connected to this one declares `key` in, with the
  # node, as its inventory has it. This node has not read it, so it has no
  # spec of it.
  defp elsewhere(nodes, key) do
    Enum.find_value(nodes.(), fn node ->
      case Map.fetch(WardrikStore.get(@inventory, inventory(node)) || %{}, to_string(key)) do
        {:ok, path} -> {:file, {path, node}, nil}
        :error -> nil
      end
    end)
  end

  @doc """
  What the policy and agent files under `dir` read into, without starting
  anything: each policy file's policy, and each agent file's definition with
  the spec it writes and where its notices go, or the message saying why it
  does not read.
  """
  @spec read_files(Path.t()) ::
          {[{Path.t(), {:ok, WardrikPolicy.t()} | {:error, String.t()}}],
           [
             {Path.t(),
              {:ok, Definition.t(), Spec.t(), WardrikNotify.Route.t() | nil}
              | {:error, String.t()}}
           ]}
  def read_files(dir) do
    policy_files = dir |> read("policies/*.{yaml,yml}", &PolicyFile.read/1) |> once_each()
    policies = for {_path, {:ok, policy}} <- policy_files, into: %{}, do: {policy.name, policy}
    {policy_files, read(dir, "agents/*.md", &agent(&1, policies))}
  end

  defp agent(path, policies) do
    with {:ok, definition} <- AgentFile.parse(path) do
      case AgentFile.spec(definition, definition.id, policies) do
        {:ok, spec, route} -> {:ok, definition, spec, route}
        {:error, message} -> {:error, "#{path}: #{message}"}
      end
    end
  end

  defp load(%{dir: dir} = state) do
    {policy_files, read} = read_files(dir)
    loaded = for {path, result} <- read, do: {path, contained(path, fn _path -> put(result) end)}
    agent_files = for {path, result} <- loaded, do: {path, spec_only(result)}
    prune(state, agent_files)
    state = %{state | files: policy_files ++ agent_files}
    problems = rebuild(state, MapSet.new(for {_path, {:ok, spec}} <- agent_files, do: spec.id))
    forget_removed()

    routes =
      for {_path, {:ok, spec, %WardrikNotify.Route{} = route}} <- loaded,
          into: %{},
          do: {spec.id, route}

    true = :ets.insert(@table, {:routes, routes})
    :ok = WardrikNotify.put_routes(routes)

    for {_path, {:error, message}} <- state.files, do: Logger.error(message)
    for message <- problems, do: Logger.error(message)

    state = %{state | problems: problems}
    true = :ets.insert(@table, {:loaded, published(state)})
    state
  end

  # Every agent awake the HTTP API defined, its conversations, and the
  # conversations of an agent a file that read declares, are brought to their
  # definitions as they read now, and why one does not build is answered. One
  # asleep takes its definition as it wakes.
  defp rebuild(state, put) do
    policies = policies(state)

    for %{id: id, asleep: false} <- Fleet.list(),
        {:ok, definition} <- [Definition.of(id)],
        rebuilt?(definition, id, put),
        message <- rebuilt(definition, id, policies),
        do: message
  end

  # A file's own agent was just put, or is left as it was where the file did
  # not read, and so are its conversations.
  defp rebuilt?(%Definition{source: {:api, _grant}}, _id, _put), do: true
  defp rebuilt?(%Definition{id: id}, id, _put), do: false
  defp rebuilt?(%Definition{id: owner}, _id, put), do: MapSet.member?(put, owner)

  # A definition the HTTP API sent outlives its agent where something other
  # than the API removed it, as the TUI does; it goes once the store no
  # longer holds the agent.
  defp forget_removed do
    for %Definition{id: id, source: {:api, _grant}} <- Definition.all(),
        not Fleet.stored?(id),
        do: :ok = drop(id)
  end

  defp rebuilt(definition, id, policies) do
    with {:ok, spec} <- build(definition, id, policies),
         {:ok, _pid} <- Fleet.put(spec) do
      []
    else
      {:error, message} when is_binary(message) ->
        ["#{id} does not build from its definition: #{message}"]

      {:error, reason} ->
        ["#{id} did not start: #{inspect(reason)}"]
    end
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

    previous = WardrikStore.get(@inventory, inventory(node())) || %{}
    kept = Map.filter(previous, fn {_key, path} -> MapSet.member?(unread, path) end)
    inventory = Map.merge(kept, declared)
    {:ok, _vsn} = WardrikStore.put(@inventory, inventory(node()), inventory)

    for text <- Map.keys(previous) -- Map.keys(inventory),
        key = Wardrik.AgentID.parse!(text),
        elsewhere(state.nodes, key) == nil,
        do: retire(key)
  end

  defp inventory(node), do: "agents/#{node}"

  defp retire(key) do
    :ok = drop(key)

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

  # The definition is kept before the agent starts, so whatever finds the
  # agent finds what it is. An agent asleep is left asleep, and takes the
  # definition as it wakes.
  defp put({:ok, definition, spec, route}) do
    :ok = keep(definition)

    case Fleet.lookup(spec.id) do
      %{asleep: true} -> {:ok, spec, route}
      _awake_or_new -> started(spec, route)
    end
  end

  defp put({:error, _message} = error), do: error

  defp started(spec, route) do
    case Fleet.put(spec) do
      {:ok, _pid} -> {:ok, spec, route}
      {:error, reason} -> {:error, "#{spec.id} did not start: #{inspect(reason)}"}
    end
  end
end
