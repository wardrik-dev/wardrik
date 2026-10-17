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
  `WardrikDefinition.Record` is kept.

  A kept definition's `notify`, whether a file or the HTTP API wrote it, is
  its agent's route: `routes/1` reads them from the store, and they are put
  with `WardrikNotify.put_routes/1` on this node and every node connected
  as a reading ends and as the API keeps or forgets a definition. So an
  agent is routed while it sleeps and as it wakes, on whichever node holds
  it, and after a restart, until its definition is forgotten.

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

  It is also the daemon's `Wardrik.Definition`. A definition sent to the
  HTTP API is kept as `WardrikDefinition.Kept` keeps one, read under the
  policies this process last read, with the grant of the token that sent
  it: `put/4` keeps it, `get/2` answers it, `delete/2` forgets it, and
  `put_trigger/4` and `delete_trigger/3` change one of its triggers.
  `create/2` writes an agent file from `config.yaml`'s `defaults`. A key
  an agent file declares, here or on any node connected to this one,
  belongs to the file: each of them refuses it with a conflict, so the API
  changes neither it nor its triggers.

  ## Reading what was read

  Files are read in its process, one reading at a time. What each reading
  comes to is published to the table `new/1` made with the value, a cache
  of the process's own, and `files/1`, `problems/1`, the policies a spec is
  built under, and whether a file declares a key are read from it in the
  caller: none of them waits behind a reading under way. Until the first
  reading is done they wait for it.

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
  says, read as a definition over the HTTP API is. `options/2` answers what
  an agent starts with, for a surface that starts one, as the TUI does: what
  the definition it runs on writes, or the defaults' where none is kept.
  `wardrik agent spawn` writes a file from them.
  """

  use GenServer

  require Logger

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.Fleet
  alias WardrikChannel.Installation
  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.PolicyFile
  alias WardrikDefinition.Kept
  alias WardrikDefinition.Record

  @inventory :declared

  @enforce_keys [:store, :config, :context, :table, :nodes]
  defstruct [:store, :config, :context, :table, :nodes, audit: Wardrik.Audit]

  @typedoc """
  The daemon's `Wardrik.Definition`: definitions kept in `:store`, read
  under `:config`, with what each reading came to published to `:table`,
  `:nodes` the other nodes whose inventories count, and `:audit` the
  `Wardrik.Audit` log an agent a channel creates is recorded in.
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
  The daemon's definitions, kept in `:store` and read under `:config`, with
  a table of their own for what each reading comes to, which the process
  that makes the value owns. `:nodes` gives the other nodes whose
  inventories count, `Node.list/0` unless given, `:audit` the log of
  `Wardrik.Host.audit/1`, `Wardrik.Audit` unless given, and `:servers` the
  `Wardrik.Servers` whose servers a definition names as its owner's,
  `Wardrik.Servers.None` unless given.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    config = Keyword.fetch!(opts, :config)

    %__MODULE__{
      store: Keyword.fetch!(opts, :store),
      config: config,
      context: %{
        AgentFile.context(config)
        | added: Keyword.get(opts, :servers, %Wardrik.Servers.None{})
      },
      table: :ets.new(__MODULE__, [:public, read_concurrency: true]),
      nodes: Keyword.get(opts, :nodes, &Node.list/0),
      audit: Keyword.get(opts, :audit, Wardrik.Audit)
    }
  end

  @doc "Starts it, reading the files under the config directory of `:agents`."
  @spec start_link(agents: t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :agents), name: __MODULE__)
  end

  @doc "Reads every file again and brings the fleet to what they say."
  @spec reload(t()) :: :ok
  def reload(_agents), do: GenServer.call(__MODULE__, :reload, :timer.minutes(1))

  @doc "Every node that runs a daemon, each of which reads its files again on `reload/1`."
  @spec reloading(t()) :: [node()]
  def reloading(_agents), do: WardrikDaemon.daemons()

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
  def offered(%__MODULE__{store: store} = agents, %Installation{channel: channel}) do
    orgs = channel_setting(agents, :orgs, channel, [])

    for %Record{id: id, fields: fields} <- Record.all(store),
        channel in WardrikDefinition.channels(fields),
        orgs == :all or id.org in orgs do
      %WardrikChannel.Offer{agent: id, description: fields["description"]}
    end
    |> Enum.sort_by(&to_string(&1.agent))
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
  @spec create_in(t(), Installation.t(), String.t(), Wardrik.Principal.t() | nil) ::
          {:ok, WardrikChannel.Offer.t()} | {:error, String.t()}
  def create_in(
        %__MODULE__{store: store} = agents,
        %Installation{channel: channel} = installation,
        room,
        by
      ) do
    description = "Answers in ##{room}."
    fields = Map.merge(defaults(agents), %{"channels" => [channel], "description" => description})

    with :ok <- creates(agents, installation),
         {:ok, id} <- created_id(agents, room, channel),
         :ok <- unkept(store, id, channel),
         {:ok, spec} <- defined(agents, id, fields, :defaults),
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
  Starts `agent`, which answers in a thread of the channel installed as
  `installation`, on the spec its definition writes, where it is not
  running.
  """
  @spec start(t(), Installation.t(), AgentID.t()) :: {:ok, pid()} | {:error, String.t()}
  def start(agents, %Installation{}, %AgentID{} = agent) do
    with {:ok, options} <- options(agents, agent) do
      case Fleet.spawn(agent, options) do
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

  @doc """
  The hooks of the policy `policies/` holds as `name`, as a ceiling over the
  agents a grant defines, or `:error` where it holds none.
  """
  @spec ceiling(t(), String.t()) :: {:ok, [Wardrik.Hook.t()]} | :error
  def ceiling(agents, name) when is_binary(name) do
    with {:ok, policy} <- Map.fetch(policies(agents), name),
         do: {:ok, WardrikPolicy.hooks(%{policy | name: "ceiling/" <> name})}
  end

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

  defp unkept(store, id, channel) do
    case Record.get(store, id) do
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
  The options the agent `key` starts with, as `Wardrik.Fleet.spawn/2` takes
  them: those of `spec/1`.
  """
  @spec options(t(), AgentID.t()) :: {:ok, keyword()} | {:error, String.t()}
  def options(agents, key) do
    with {:ok, spec} <- spec(agents, key), do: {:ok, Spec.options(spec)}
  end

  @doc """
  The spec the agent `key` runs on: `build/2`'s, from the definition it runs
  on, as `WardrikDefinition.Record.of/2` finds it in the store, or from
  `defaults/1` where none is kept.
  """
  @spec spec(t(), AgentID.t()) :: {:ok, Spec.t()} | {:error, String.t()}
  def spec(%__MODULE__{store: store} = agents, key) do
    # Asked first, so the files have been read once before the store is.
    policies = policies(agents)

    definition =
      case Record.of(store, key) do
        {:ok, record} ->
          {:ok, record}

        {:error, :not_found} ->
          Record.define(agents.context, AgentID.put_external_id(key, nil),
            fields: defaults(agents),
            source: :defaults
          )
      end

    with {:ok, definition} <- definition, do: Kept.build(kept(agents, policies), definition, key)
  end

  @doc """
  The spec the definition kept for `key` writes now, for it or the agent it
  is a conversation of, or `:none` where none is kept or it does not build.
  An agent asks it as it starts or wakes, so a definition changed while the
  agent slept is the one it wakes with; see `Wardrik.Agent`.

  Until the files are first read it answers `:none` without waiting: the
  reading puts every agent a file declares, and brings every agent awake
  that a kept definition writes to it, so one starting meanwhile, as each a
  reading puts does, is brought to it then.
  """
  def current(%__MODULE__{} = agents, key) do
    case read_policies(agents) do
      {:ok, policies} -> Kept.current(kept(agents, policies), key)
      :reading -> :none
    end
  end

  defp read_policies(%__MODULE__{table: table}) do
    case :ets.lookup(table, :loaded) do
      [{:loaded, loaded}] -> {:ok, loaded.policies}
      [] -> :reading
    end
  end

  @doc """
  Defines the agent `key`, which nothing declares or keeps, by writing
  `agents/NAME.md`, or `agents/USER-NAME.md` for a user's agent, from
  `config.yaml`'s `defaults`, with its org and user where they are not the
  deployment's, then reading the files again on every node; answers the
  spec the file writes. The file is written only
  once the defaults are known to make an agent under the key, and never over
  one that is there, which is a conflict saying what it declares.
  """
  def create(%__MODULE__{} = agents, %AgentID{} = key) do
    path = Path.join([dir(agents), "agents", file_name(key) <> ".md"])

    with :ok <- untaken(agents, path),
         {:ok, _options} <- created(agents, key),
         :ok <- write(path, AgentFile.text(created_fields(agents, key))) do
      :ok = Wardrik.Definitions.reload_on(agents, reloading(agents))
      written(agents, path)
    end
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

  defp created(agents, key) do
    case options(agents, key) do
      {:ok, options} ->
        {:ok, options}

      {:error, message} ->
        {:error, "config.yaml's defaults do not make an agent for #{key}: #{message}"}
    end
  end

  defp write(path, text) do
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
      for key <- WardrikDefinition.default_keys() -- ["idle_timeout"],
          Map.has_key?(defaults, key),
          do: {key, defaults[key]}
  end

  defp written(agents, path) do
    case List.keyfind(files(agents), path, 0) do
      {^path, {:ok, spec}} -> {:ok, spec}
      {^path, {:error, message}} -> {:error, message}
    end
  end

  defp shown(path), do: Path.join("agents", Path.basename(path))

  @doc """
  The spec `definition` writes for the agent `key`, its own or one of its
  conversations, under the policies last read, and under the ceiling of the
  token that sent it where one did.
  """
  @spec build(t(), Record.t(), AgentID.t()) :: {:ok, Spec.t()} | {:error, String.t()}
  def build(agents, %Record{} = definition, key),
    do: Kept.build(kept(agents, policies(agents)), definition, key)

  # API-defined agents are kept as the library keeps them, read under the
  # policies of this reading.
  defp kept(%__MODULE__{context: context} = agents, policies),
    do: %Kept{store: agents.store, contexts: %{context | policies: policies}, nodes: agents.nodes}

  defp kept(%__MODULE__{context: context} = agents), do: kept(agents, context.policies)

  defp policies(agents), do: loaded(agents).policies

  # Published at the end of each reading. Before the first one there is
  # nothing to read, so the process is asked, and answers once it is done.
  defp loaded(%__MODULE__{table: table}) do
    case :ets.lookup(table, :loaded) do
      [{:loaded, loaded}] -> loaded
      [] -> GenServer.call(__MODULE__, :loaded, :timer.minutes(1))
    end
  end

  @doc """
  The spec a definition sent to the HTTP API writes for the agent `key`, sent
  by a token holding `grant`, which it keeps, routing its notices as it says;
  or a conflict where an agent file declares it.
  """
  def put(%__MODULE__{} = agents, key, opts),
    do:
      defined(
        agents,
        key,
        Keyword.fetch!(opts, :definition),
        {:api, Keyword.fetch!(opts, :grant)}
      )

  defp defined(%__MODULE__{} = agents, key, fields, source) do
    with {:ok, kept} <- editable_kept(agents, key),
         do: Kept.define(kept, key, fields: fields, source: source)
  end

  @doc "The definition kept for the agent `key`, as the HTTP API writes one."
  def get(%__MODULE__{} = agents, key), do: Kept.get(kept(agents), key)

  @doc """
  Forgets the definition the HTTP API sent for the agent `key`:
  `{:error, :not_found}` where none was kept, or a conflict where an agent
  file declares `key`.
  """
  def delete(%__MODULE__{} = agents, key) do
    with {:ok, kept} <- editable_kept(agents, key), do: Kept.delete(kept, key)
  end

  @doc """
  Sets the trigger `name` in the definition the HTTP API sent for the agent
  `key`, from `fields` as `WardrikDefinition.Record.put_trigger/3` reads
  them, and brings the agent's triggers to it: whether it was added or
  changed, and the trigger as `WardrikTrigger.encode/1` writes it.
  `{:error, :not_found}` where no definition is kept, or a conflict where an
  agent file declares `key`.
  """
  def put_trigger(%__MODULE__{} = agents, key, name, opts) do
    with {:ok, kept} <- editable_kept(agents, key), do: Kept.put_trigger(kept, key, name, opts)
  end

  @doc """
  Deletes the trigger `name` from the definition the HTTP API sent for the
  agent `key`, and stops it: `{:error, :not_found}` where neither is kept, or
  a conflict where an agent file declares `key`.
  """
  def delete_trigger(%__MODULE__{} = agents, key, name) do
    with {:ok, kept} <- editable_kept(agents, key), do: Kept.delete_trigger(kept, key, name)
  end

  @doc """
  `:ok` where an operation may change or forget the agent `key`, or a
  conflict where a file declares it.
  """
  def editable(%__MODULE__{} = agents, key) do
    with {:ok, _kept} <- editable_kept(agents, key), do: :ok
  end

  # The definitions the API keeps, read under the policies last read, where
  # no file declares `key`.
  defp editable_kept(agents, key) do
    case owner(agents, key) do
      {:file, path, _spec} -> declared(key, path)
      {:api, policies} -> {:ok, kept(agents, policies)}
    end
  end

  @doc """
  Deletes the definition kept for the agent `key`, the triggers it lists
  and its route, as `wardrik agent rm` does once it has forgotten the agent.
  """
  @spec drop(t(), AgentID.t()) :: :ok
  def drop(%__MODULE__{} = agents, key), do: Kept.drop(kept(agents), key)

  @doc """
  Why each agent `reload/0` last built again from a kept definition did not
  build, a message each.
  """
  @spec problems(t()) :: [String.t()]
  def problems(agents), do: loaded(agents).problems

  @doc """
  The route of each agent a kept definition routes, a file's or the HTTP
  API's, as `WardrikDefinition.Record.route/2` reads it. Read from the store
  rather than asked of the process, so `WardrikNotify` can ask as it starts,
  while a reading is putting them to it. A definition whose `notify` no
  longer reads, as one naming a target `config.yaml` no longer has, routes
  nothing.
  """
  @spec routes(t()) :: %{AgentID.t() => WardrikNotify.Route.t()}
  def routes(%__MODULE__{} = agents), do: Kept.routes(kept(agents))

  defp declared(key, {path, node}),
    do:
      {:error, :conflict,
       "#{key} is declared by agents/#{Path.basename(path)} on #{node}; change or remove that " <>
         "file, then wardrik reload reads it"}

  defp declared(key, path),
    do:
      {:error, :conflict,
       "#{key} is declared by agents/#{Path.basename(path)}; change or remove that file, then " <>
         "wardrik reload reads it"}

  # Whether a file declares `key`, here with its spec or on another node, or
  # the policies a definition the API sends for it is read under.
  defp owner(%__MODULE__{store: store} = agents, key) do
    %{files: files, policies: policies} = loaded(agents)

    file =
      Enum.find_value(files, fn
        {path, {:ok, %Spec{} = spec}} -> if spec.id == key, do: {:file, path, spec}
        _other -> nil
      end)

    file || elsewhere(store, agents.nodes, key) || {:api, policies}
  end

  @impl true
  def init(%__MODULE__{} = agents) do
    # A reading of a process before this one is not this one's: until its
    # first is done, the process is asked, and answers once it is.
    true = :ets.delete(agents.table, :loaded)

    state = %{agents: agents, store: agents.store, nodes: agents.nodes, files: [], problems: []}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_call(:reload, _from, state), do: {:reply, :ok, load(state)}

  def handle_call(:loaded, _from, state), do: {:reply, published(state), state}

  defp policies_of(state) do
    for {_path, {:ok, %WardrikPolicy{} = policy}} <- state.files,
        into: %{},
        do: {policy.name, policy}
  end

  defp published(state),
    do: %{files: state.files, policies: policies_of(state), problems: state.problems}

  # The file another node connected to this one declares `key` in, with the
  # node, as its inventory has it. This node has not read it, so it has no
  # spec of it.
  defp elsewhere(store, nodes, key) do
    Enum.find_value(nodes.(), fn node ->
      case Map.fetch(WardrikStore.get(store, @inventory, inventory(node)) || %{}, to_string(key)) do
        {:ok, path} -> {:file, {path, node}, nil}
        :error -> nil
      end
    end)
  end

  @doc """
  What the policy and agent files under `dir` read into, without starting
  anything: each policy file's policy, and each agent file's definition with
  the spec it writes, or the message saying why it does not read.
  """
  @spec read_files(WardrikDaemon.Config.t()) ::
          {[{Path.t(), {:ok, WardrikPolicy.t()} | {:error, String.t()}}],
           [{Path.t(), {:ok, Record.t(), Spec.t()} | {:error, String.t()}}]}
  def read_files(%WardrikDaemon.Config{config_dir: dir} = config) do
    context = AgentFile.context(config)
    policy_files = dir |> read("policies/*.{yaml,yml}", &PolicyFile.read/1) |> once_each()
    policies = for {_path, {:ok, policy}} <- policy_files, into: %{}, do: {policy.name, policy}
    {policy_files, read(dir, "agents/*.md", &agent(%{context | policies: policies}, &1))}
  end

  defp agent(context, path) do
    with {:ok, definition} <- AgentFile.parse(context, path) do
      case Record.spec(definition, definition.id, context: context) do
        {:ok, spec} -> {:ok, definition, spec}
        {:error, message} -> {:error, "#{path}: #{message}"}
      end
    end
  end

  defp load(%{agents: agents} = state) do
    {policy_files, read} = read_files(agents.config)

    agent_files =
      for {path, result} <- read,
          do: {path, contained(path, fn _path -> put(agents, result) end)}

    prune(state, agent_files)
    state = %{state | files: policy_files ++ agent_files}
    put = MapSet.new(for {_path, {:ok, spec}} <- agent_files, do: spec.id)

    problems =
      Kept.rebuild(kept(agents, policies_of(state)), only: &rebuilt?(&1, &2, put))

    kept = kept(agents)
    :ok = Kept.forget_removed(kept)
    :ok = Kept.route(kept)

    for {_path, {:error, message}} <- state.files, do: Logger.error(message)
    for message <- problems, do: Logger.error(message)

    state = %{state | problems: problems}
    true = :ets.insert(agents.table, {:loaded, published(state)})
    state
  end

  # Every agent awake the HTTP API defined, its conversations, and the
  # conversations of an agent a file that read declares, are built again. A
  # file's own agent was just put, or is left as it was where the file did
  # not read, and so are its conversations.
  defp rebuilt?(%Record{source: {:file, _name}, id: id}, id, _put), do: false

  defp rebuilt?(%Record{source: {:file, _name}, id: owner}, _id, put),
    do: MapSet.member?(put, owner)

  defp rebuilt?(_record, _id, _put), do: true

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
    :ok = drop(agents, key)

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
  # agent finds what it is. An agent asleep is left asleep, and takes the
  # definition as it wakes.
  defp put(agents, {:ok, definition, spec}) do
    :ok = Kept.keep(kept(agents), definition)

    case Fleet.lookup(spec.id) do
      %{asleep: true} -> {:ok, spec}
      _awake_or_new -> started(spec)
    end
  end

  defp put(_agents, {:error, _message} = error), do: error

  defp started(spec) do
    case Fleet.put(spec) do
      {:ok, _pid} -> {:ok, spec}
      {:error, reason} -> {:error, "#{spec.id} did not start: #{inspect(reason)}"}
    end
  end
end

defimpl Wardrik.Definition, for: WardrikDaemon.Agents do
  defdelegate put(agents, id, opts), to: WardrikDaemon.Agents
  defdelegate get(agents, id), to: WardrikDaemon.Agents
  defdelegate delete(agents, id), to: WardrikDaemon.Agents
  defdelegate put_trigger(agents, id, name, opts), to: WardrikDaemon.Agents
  defdelegate delete_trigger(agents, id, name), to: WardrikDaemon.Agents
  defdelegate editable(agents, id), to: WardrikDaemon.Agents
  defdelegate current(agents, id), to: WardrikDaemon.Agents
  defdelegate create(agents, id), to: WardrikDaemon.Agents
  defdelegate reload(agents), to: WardrikDaemon.Agents
  defdelegate reloading(agents), to: WardrikDaemon.Agents
end
