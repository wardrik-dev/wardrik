defmodule WardrikDaemon.Agents do
  @moduledoc """
  Runs the agents `agents/` in the config directory declares, one per `*.md`
  file, under the policies `policies/` declares, one per `*.yaml` or `*.yml`
  file. See
  `WardrikDaemon.AgentFile` and `WardrikDaemon.PolicyFile` for what each says.

  It reads every file when it starts and again on `reload/1`, policies first,
  keeps the policies in the store, and each agent file's `Wardrik.Definition`
  in the daemon's `Wardrik.Definitions`, then puts each agent's
  `Wardrik.Agent.Spec` to the fleet with `Wardrik.Fleet.put/1`: an agent
  that is not running is started, and one that is takes what its file says
  now. An agent keeps its conversation either way.

  It is also the `WardrikDefinition.Contexts` of the daemon's definitions,
  `definitions/1`: every definition, a file's or one the HTTP API sent, is
  read under the context `config.yaml` gives, with the policies the store
  keeps, so every node reads the same ones; and `wardrik reload` has every
  daemon of the deployment read its files again.

  A file that does not read, or whose agent does not start, is reported by
  `files/1`, and by `wardrik status`, and every other file is read as if it
  were not there. An agent already running for it is left as it was, and an
  agent naming a policy that does not read does not read either.

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

  ## Reading what was read

  Files are read in its process, one reading at a time. What each reading
  comes to is published to the table `new/1` made with the value, a cache
  of the process's own, and `files/1` is read from it in the caller: it
  does not wait behind a reading under way. Until the first reading is done
  it waits for it.

  ## Defaults

  `config.yaml`'s `defaults` is what an agent is given where nothing else
  says: an agent nothing defines starts from them, and `write/2` writes a
  file from them, as `wardrik agent spawn --file` asks.
  """

  use GenServer

  require Logger

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Fleet
  alias WardrikChannel.Installation
  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.PolicyFile

  @inventory :declared
  @policies :policies

  @enforce_keys [:store, :config, :context, :table, :nodes]
  defstruct [:store, :config, :context, :table, :nodes, audit: Wardrik.Audit]

  @typedoc """
  The daemon's agents: definitions kept in `:store`, read under `:config`,
  with what each reading came to published to `:table`, `:nodes` the other
  nodes whose inventories count, and `:audit` the `Wardrik.Audit` log an
  agent a channel creates is recorded in.
  """
  @type t() :: %__MODULE__{
          store: WardrikStore.t(),
          config: WardrikDaemon.Config.t(),
          context: WardrikDefinition.Context.t(),
          table: :ets.tid(),
          nodes: (-> [node()]),
          audit: GenServer.name()
        }

  @typedoc "What became of one file: the spec or policy it writes, or why it writes neither."
  @type file() :: {Path.t(), {:ok, Spec.t() | WardrikPolicy.t()} | {:error, String.t()}}

  @doc """
  The daemon's agents, kept in `:store` and read under `:config`, with a
  table of their own for what each reading comes to, which the process
  that makes the value owns. `:nodes` gives the other nodes whose
  inventories count, `Node.list/0` unless given, `:audit` the log of
  `Wardrik.Host.audit/1`, `Wardrik.Audit` unless given.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    config = Keyword.fetch!(opts, :config)

    %__MODULE__{
      store: Keyword.fetch!(opts, :store),
      config: config,
      context: AgentFile.context(config),
      table: :ets.new(__MODULE__, [:public, read_concurrency: true]),
      nodes: Keyword.get(opts, :nodes, &Node.list/0),
      audit: Keyword.get(opts, :audit, Wardrik.Audit)
    }
  end

  @doc "The daemon's definitions: kept in its store, and read under it."
  @spec definitions(t()) :: Definitions.t()
  def definitions(%__MODULE__{} = agents),
    do: %Definitions{store: agents.store, contexts: agents, nodes: agents.nodes}

  @doc "The agents of the daemon `host` runs: the contexts of its definitions."
  @spec of(Wardrik.Host.t()) :: t()
  def of(host), do: Wardrik.Host.definitions(host).contexts

  @doc """
  Starts it, reading the files under the config directory of `:agents`, and
  bringing the agents awake on `:host` to them.
  """
  @spec start_link(agents: t(), host: Wardrik.Host.t()) :: GenServer.on_start()
  def start_link(opts) do
    init = {Keyword.fetch!(opts, :agents), Keyword.fetch!(opts, :host)}
    GenServer.start_link(__MODULE__, init, name: __MODULE__)
  end

  @doc "Reads every file again and brings the fleet to what they say."
  @spec reload(t()) :: :ok
  def reload(_agents), do: GenServer.call(__MODULE__, :reload, :timer.minutes(1))

  @doc """
  Has every node that runs a daemon read its files again, as
  `Wardrik.deployment_reload/1` asks: the nodes that read.
  """
  @spec reload_everywhere(t()) :: [node()]
  def reload_everywhere(agents) do
    nodes = WardrikDaemon.daemons()

    for node <- nodes,
        do: :ok = :erpc.call(node, __MODULE__, :reload, [agents], :timer.minutes(1))

    nodes
  end

  @doc """
  The context every definition is read under: what `config.yaml` says, with
  the policies the store keeps, as the last reading of `policies/` put them.
  """
  @spec context(t()) :: WardrikDefinition.Context.t()
  def context(%__MODULE__{context: context, store: store}),
    do: %{context | policies: WardrikStore.get(store, @policies, "policies") || %{}}

  @doc """
  What became of each file the last time they were read: the policies, then
  the agents, each in the order of their names.
  """
  @spec files(t()) :: [file()]
  def files(agents), do: loaded(agents).files

  @doc "The config directory the files are read from."
  @spec dir(t()) :: Path.t()
  def dir(%__MODULE__{config: config}), do: config.config_dir

  @doc "`config.yaml`'s `defaults`, as the file writes them, or none."
  @spec defaults(t()) :: map()
  def defaults(%__MODULE__{context: context}), do: context.defaults

  @doc """
  The agents offered in the rooms of the channel installed as
  `installation`, as `WardrikChannel.Context` asks: those whose definitions
  name the channel, of the orgs `config.yaml` has the channel serve, each
  with its `description`. Sorted by ID.
  """
  @spec offered(t(), Installation.t()) :: [WardrikChannel.Offer.t()]
  def offered(%__MODULE__{} = agents, %Installation{channel: channel}) do
    orgs = channel_setting(agents, :orgs, channel, [])

    for %Definition{id: id, channels: channels, description: description} <-
          Definitions.list(definitions(agents), Wardrik.Resource.parse!("*")),
        channel in channels,
        orgs == :all or id.org in orgs,
        do: %WardrikChannel.Offer{agent: id, description: description}
  end

  @doc """
  Whether someone in a room of the channel installed as `installation` may
  create an agent to answer there: where the channel's `create` is not
  `false`, and `config.yaml`'s `defaults`, which such an agent starts from,
  name a policy its calls are held to.
  """
  @spec creatable?(t(), Installation.t()) :: boolean()
  def creatable?(agents, %Installation{channel: channel}),
    do:
      channel_setting(agents, :creates, channel, true) and is_map_key(defaults(agents), "policy")

  @doc """
  Creates an agent for the room `room` of the channel installed as
  `installation`, as `by` asked: named after the room, in the channel's
  org, from `config.yaml`'s `defaults`, offered in the channel. It is kept
  as a definition the HTTP API sent is, and recorded in `Wardrik.Audit` as
  defined by `by`.
  """
  @spec create_in(Wardrik.Host.t(), Installation.t(), String.t(), Wardrik.Principal.t() | nil) ::
          {:ok, WardrikChannel.Offer.t()} | {:error, String.t()}
  def create_in(host, %Installation{channel: channel} = installation, room, by) do
    agents = of(host)
    description = "Answers in ##{room}."
    fields = Map.merge(defaults(agents), %{"channels" => [channel], "description" => description})
    definitions = definitions(agents)

    with :ok <- creates(agents, installation),
         {:ok, id} <- created_id(agents, room, channel),
         :ok <- unkept(definitions, id, channel),
         {:ok, definition} <-
           Definition.read(fields, id: id, source: :defaults, context: context(agents)),
         {:ok, spec} <-
           Definition.spec(definition, id, context: context(agents), host: host),
         :ok <- Definitions.put(definitions, definition),
         {:ok, _pid} <- Fleet.put(spec) do
      :ok = Wardrik.Audit.record(agents.audit, {:agent_defined, id}, by: by)
      {:ok, %WardrikChannel.Offer{agent: id, description: description}}
    else
      {:error, :conflict, message} -> {:error, message}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "The agent did not start: #{inspect(reason)}"}
    end
  end

  @doc """
  Starts `agent` on `host`, whose definitions are the daemon's, which
  answers in a thread of the channel installed as `installation`, on the
  spec its definition writes, where it is not running.
  """
  @spec start(Wardrik.Host.t(), Installation.t(), AgentID.t()) ::
          {:ok, pid()} | {:error, String.t()}
  def start(host, %Installation{}, %AgentID{} = agent) do
    with {:ok, spec} <- spec(of(host), agent, host: host) do
      case Fleet.spawn(agent, Spec.options(spec)) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, "#{agent} did not start: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Who decides what agents wait on in the channel installed as
  `installation`, as its `approvers` say.
  """
  @spec approvers(t(), Installation.t()) :: WardrikChannel.Approvers.t()
  def approvers(agents, %Installation{channel: channel}),
    do: channel_setting(agents, :approvers, channel, %WardrikChannel.Approvers.Named{names: []})

  @doc "How an agent comes to answer in the rooms of the channel installed as `installation`."
  @spec offering(Installation.t()) :: String.t()
  def offering(%Installation{channel: channel}),
    do:
      "Whoever runs Wardrik can offer an agent here by adding `channels: [#{channel}]` " <>
        "to its agent file."

  @doc "Who else may decide what agents ask in the channel installed as `installation`."
  @spec deciding(Installation.t()) :: String.t()
  def deciding(%Installation{}),
    do:
      "The channel's approvers in config.yaml name who else may, and wardrik approve " <>
        "answers it from the server."

  @doc "The installation of the channel `channel`, in the workspace its token reaches."
  @spec installation(t(), String.t()) :: {:ok, Installation.t()} | :error
  def installation(agents, channel) when is_binary(channel) do
    agents.config
    |> WardrikDaemon.Config.section(WardrikChannel)
    |> Keyword.fetch!(:installations)
    |> WardrikChannel.Installations.fetch(channel, channel)
  end

  @doc "Who may change the agents of the channel `channel`'s orgs, as it names people."
  @spec admins(t(), String.t()) :: [String.t()]
  def admins(agents, channel) when is_binary(channel),
    do: channel_setting(agents, :admins, channel, [])

  @doc "The orgs whose agents the channel `channel` offers, or `:all`."
  @spec orgs(t(), String.t()) :: [String.t()] | :all
  def orgs(agents, channel) when is_binary(channel),
    do: channel_setting(agents, :orgs, channel, [])

  defp creates(agents, installation) do
    if creatable?(agents, installation),
      do: :ok,
      else: {:error, "Agents are not created from here; whoever runs Wardrik can offer one."}
  end

  # An agent's name, from the room's, in the channel's own org.
  defp created_id(agents, room, channel) do
    name = room |> String.downcase() |> String.replace(~r/[^a-z0-9_-]+/u, "-") |> String.trim("-")

    org =
      case channel_setting(agents, :orgs, channel, :all) do
        [org | _] -> org
        _every -> WardrikDaemon.Config.org(agents.config)
      end

    case AgentID.new(name, org: org) do
      {:ok, id} -> {:ok, id}
      {:error, _message} -> {:error, "#{inspect(room)} makes no agent's name."}
    end
  end

  defp unkept(definitions, id, channel) do
    case Definitions.get(definitions, id) do
      {:error, :not_found} ->
        :ok

      {:ok, _definition} ->
        {:error,
         "#{id} is there already. Whoever runs Wardrik can offer it here by adding " <>
           "`channels: [#{channel}]` to it."}
    end
  end

  # What config.yaml says of the channel `channel` under `key`.
  defp channel_setting(agents, key, channel, default) do
    settings =
      agents.config |> WardrikDaemon.Config.section(WardrikChannel) |> Keyword.get(key, [])

    case Enum.find(settings, fn {name, _value} -> Atom.to_string(name) == channel end) do
      {_name, value} -> value
      nil -> default
    end
  end

  @doc """
  The spec the agent `key` runs on, on `:host`: the one its definition, or
  that of the agent it is a conversation of, writes, or the one
  `defaults/1` write where none is kept.
  """
  @spec spec(t(), AgentID.t(), host: Wardrik.Host.t()) :: {:ok, Spec.t()} | {:error, String.t()}
  def spec(%__MODULE__{} = agents, %AgentID{} = key, opts) do
    case Definitions.spec(definitions(agents), key, opts) do
      {:error, :not_found} -> defaulted(agents, key, opts)
      written -> written
    end
  end

  defp defaulted(agents, key, opts) do
    owner = AgentID.put_external_id(key, nil)
    context = context(agents)

    with {:ok, definition} <-
           Definition.read(defaults(agents), id: owner, source: :defaults, context: context),
         do: Definition.spec(definition, key, context: context, host: Keyword.fetch!(opts, :host))
  end

  @doc """
  Writes `agents/NAME.md`, or `agents/USER-NAME.md` for a user's agent, for
  the agent `key`, from `config.yaml`'s `defaults`, with its org and user
  where they are not the deployment's: the path it wrote. The file is
  written only once the defaults are known to make an agent under the key
  on `:host`, and never over one that is there, which is a conflict saying
  what it declares.
  """
  @spec write(t(), AgentID.t(), host: Wardrik.Host.t()) ::
          {:ok, Path.t()} | {:error, String.t()} | {:error, :conflict, String.t()}
  def write(%__MODULE__{} = agents, %AgentID{} = key, opts) do
    path = Path.join([dir(agents), "agents", file_name(key) <> ".md"])

    with :ok <- untaken(agents, path),
         {:ok, _spec} <- created(agents, key, opts),
         :ok <- written(path, AgentFile.text(created_fields(agents, key))),
         do: {:ok, path}
  end

  defp untaken(agents, path) do
    cond do
      not File.exists?(path) ->
        :ok

      other = Enum.find_value(WardrikDaemon.declared(files(agents)), &declaring(&1, path)) ->
        {:error, :conflict, "#{shown(path)} is there already, and declares #{other}."}

      true ->
        {:error, :conflict,
         "#{shown(path)} is there already, and is kept as it is: wardrik reload reads it, " <>
           "and wardrik status says why where it does not."}
    end
  end

  defp declaring({key, {path, _spec}}, path), do: key
  defp declaring(_declared, _path), do: nil

  defp created(agents, key, opts) do
    case defaulted(agents, key, opts) do
      {:ok, spec} ->
        {:ok, spec}

      {:error, message} ->
        {:error, "config.yaml's defaults do not make an agent for #{key}: #{message}"}
    end
  end

  defp written(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, text, [:exclusive]) do
      :ok
    else
      {:error, reason} ->
        {:error, "#{shown(path)} could not be written: #{:file.format_error(reason)}"}
    end
  end

  # Each person's agent has a file of its own, as every person's assistant.
  defp file_name(%AgentID{user: nil, name: name}), do: name
  defp file_name(%AgentID{user: user, name: name}), do: "#{user}-#{name}"

  # The name where the file's is not the agent's, the org and user where
  # they are not the deployment's own, then the defaults every new agent is
  # written with.
  defp created_fields(agents, %AgentID{org: org, user: user, name: name} = key) do
    named = if file_name(key) != name, do: [{"name", name}], else: []

    named =
      if org != WardrikDaemon.Config.org(agents.config), do: named ++ [{"org", org}], else: named

    named = if user, do: named ++ [{"user", user}], else: named
    defaults = defaults(agents)

    named ++
      for key <- Definition.default_keys() -- ["idle_timeout"],
          Map.has_key?(defaults, key),
          do: {key, defaults[key]}
  end

  defp shown(path), do: Path.join("agents", Path.basename(path))

  # Published at the end of each reading. Before the first one there is
  # nothing to read, so the process is asked, and answers once it is done.
  defp loaded(%__MODULE__{table: table}) do
    case :ets.lookup(table, :loaded) do
      [{:loaded, loaded}] -> loaded
      [] -> GenServer.call(__MODULE__, :loaded, :timer.minutes(1))
    end
  end

  @doc """
  Why each agent `reload/1` last built again from a kept definition did not
  build, a message each.
  """
  @spec problems(t()) :: [String.t()]
  def problems(agents), do: loaded(agents).problems

  @impl true
  def init({%__MODULE__{} = agents, host}) do
    # A reading of a process before this one is not this one's: until its
    # first is done, the process is asked, and answers once it is.
    true = :ets.delete(agents.table, :loaded)

    state = %{agents: agents, host: host, store: agents.store, nodes: agents.nodes}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_call(:reload, _from, state), do: {:reply, :ok, load(state)}

  def handle_call(:loaded, _from, state), do: {:reply, published(state), state}

  defp published(state), do: Map.take(state, [:files, :problems])

  # The file another node connected to this one declares `key` in, as its
  # inventory has it.
  defp elsewhere(store, nodes, key) do
    Enum.find_value(nodes.(), fn node ->
      Map.get(WardrikStore.get(store, @inventory, inventory(node)) || %{}, to_string(key))
    end)
  end

  @doc """
  What the policy and agent files under `config`'s directory read into on
  `:host`, without starting anything: each policy file's policy, and each
  agent file's definition with the spec it writes, or the message saying
  why it does not read.
  """
  @spec read_files(WardrikDaemon.Config.t(), host: Wardrik.Host.t()) ::
          {[{Path.t(), {:ok, WardrikPolicy.t()} | {:error, String.t()}}],
           [{Path.t(), {:ok, Definition.t(), Spec.t()} | {:error, String.t()}}]}
  def read_files(%WardrikDaemon.Config{config_dir: dir} = config, opts) do
    host = Keyword.fetch!(opts, :host)
    context = AgentFile.context(config)
    policy_files = dir |> read("policies/*.{yaml,yml}", &PolicyFile.read/1) |> once_each()
    policies = for {_path, {:ok, policy}} <- policy_files, into: %{}, do: {policy.name, policy}
    {policy_files, read(dir, "agents/*.md", &agent(%{context | policies: policies}, host, &1))}
  end

  defp agent(context, host, path) do
    with {:ok, definition} <- AgentFile.parse(context, path) do
      case Definition.spec(definition, definition.id, context: context, host: host) do
        {:ok, spec} -> {:ok, definition, spec}
        {:error, message} -> {:error, "#{path}: #{message}"}
      end
    end
  end

  # The policies are kept first, so the definitions the files write read
  # under them wherever they are built.
  defp load(%{agents: agents} = state) do
    {policy_files, read} = read_files(agents.config, host: state.host)
    policies = for {_path, {:ok, policy}} <- policy_files, into: %{}, do: {policy.name, policy}
    {:ok, _vsn} = WardrikStore.put(state.store, @policies, "policies", policies)

    agent_files =
      for {path, result} <- read,
          do: {path, contained(path, fn _path -> put(agents, result) end)}

    prune(state, agent_files)
    problems = Definitions.rebuild(definitions(agents), host: state.host)

    state = Map.merge(state, %{files: policy_files ++ agent_files, problems: problems})
    for {_path, {:error, message}} <- state.files, do: Logger.error(message)
    for message <- problems, do: Logger.error(message)

    true = :ets.insert(agents.table, {:loaded, published(state)})
    state
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

    previous = WardrikStore.get(state.store, @inventory, inventory(node())) || %{}
    kept = Map.filter(previous, fn {_key, path} -> MapSet.member?(unread, path) end)
    inventory = Map.merge(kept, declared)
    {:ok, _vsn} = WardrikStore.put(state.store, @inventory, inventory(node()), inventory)

    for text <- Map.keys(previous) -- Map.keys(inventory),
        key = Wardrik.AgentID.parse!(text),
        elsewhere(state.store, state.nodes, key) == nil,
        do: retire(state.agents, key)
  end

  defp inventory(node), do: "agents/#{node}"

  defp retire(agents, key) do
    _forgotten = Definitions.delete(definitions(agents), key)

    case Fleet.stop(key) do
      :ok -> :ok
      {:error, :noproc} -> :ok
    end
  end

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
  # agent finds what it is. An agent the store holds asleep is left asleep,
  # and takes the definition as it wakes.
  defp put(agents, {:ok, definition, spec}) do
    :ok = Definitions.put(definitions(agents), definition)

    if Fleet.held_pid(spec.id, wake: false) == nil and Fleet.stored?(spec.id),
      do: {:ok, spec},
      else: started(spec)
  end

  defp put(_agents, {:error, _message} = error), do: error

  defp started(spec) do
    case Fleet.put(spec) do
      {:ok, _pid} -> {:ok, spec}
      {:error, reason} -> {:error, "#{spec.id} did not start: #{inspect(reason)}"}
    end
  end
end

defimpl WardrikDefinition.Contexts, for: WardrikDaemon.Agents do
  def context(agents, _owner), do: WardrikDaemon.Agents.context(agents)
  def reload(agents, _opts), do: WardrikDaemon.Agents.reload_everywhere(agents)
end
