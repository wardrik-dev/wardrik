defmodule WardrikDefinition.Kept do
  @moduledoc """
  Definitions kept in the store, for a host that defines its agents through
  operations: a `Wardrik.Definition` the host names on its `Wardrik.Host`.

      context = %WardrikDefinition.Context{org: "acme", orgs: ["acme"]}
      definitions = %WardrikDefinition.Kept{store: store, contexts: context}

      host =
        Wardrik.Host.new(store: store, definitions: definitions)
        |> Wardrik.Host.register(:tools, [{"search", MyApp.Search}])

      children = [
        {WardrikStore, store},
        {Wardrik.Core, host: host},
        {WardrikTrigger, store: store, host: host}
      ]

  Each definition is read under the `WardrikDefinition.Context` its
  `:contexts` give the agent that owns it (see `WardrikDefinition.Contexts`),
  on the host asking, whose tools, sources and runtimes it names, and kept
  as a `WardrikDefinition.Record` with the token of whoever sent it, whose
  policy holds the agent each time its spec is built, and the hooks they
  held it to.

  | Callback | What it does |
  | --- | --- |
  | `put/3` | reads the definition, keeps it, and answers the spec it writes |
  | `get/3` | the definition kept, as it was sent |
  | `delete/2` | forgets it, its triggers and its route |
  | `put_trigger/4`, `delete_trigger/3` | change one trigger of the definition kept |
  | `editable/2` | every agent may be changed or forgotten |
  | `current/3` | the spec the definition kept writes now, as an agent starts or wakes |
  | `defined/2` | the agents a definition is kept for, read from the store's keys |
  | `create/3` | `:unsupported`: an agent nothing defines is not found |
  | `reload/2` | builds every agent awake on the host given again |
  | `reloading/1` | this node: the records are in the store every node shares |

  A definition's `triggers` are its agent's, brought to what it lists as it
  is kept with `WardrikTrigger.sync/2`, so a host that keeps definitions
  starts `WardrikTrigger`. Where its notices go is put to `WardrikNotify` on
  this node and on every node `:nodes` gives as a definition is kept or
  forgotten, so an agent is routed wherever it runs; a node not running
  `WardrikNotify.Supervisor` routes nothing.
  """

  require Logger

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.Fleet
  alias Wardrik.Resource
  alias WardrikDefinition.Contexts
  alias WardrikDefinition.Record

  @enforce_keys [:store, :contexts]
  defstruct [:store, :contexts, nodes: &Node.list/0]

  @typedoc """
  Definitions kept in `:store`, each read under what `:contexts` gives its
  agent's owner; `:nodes` are the other nodes routes are put to.
  """
  @type t() :: %__MODULE__{
          store: WardrikStore.t(),
          contexts: Contexts.t(),
          nodes: (-> [node()])
        }

  @doc """
  Reads the definition `:definition` of the agent `id`, sent with the
  `:token` given, on `:host`, keeps it with the hooks it is `:held` to, none
  unless given, and answers the spec it writes, not yet held to them.
  """
  @spec put(t(), AgentID.t(),
          definition: map(),
          token: Wardrik.Token.t(),
          held: [Wardrik.Hook.t()],
          host: Wardrik.Host.t()
        ) :: {:ok, Spec.t()} | {:error, String.t()}
  def put(%__MODULE__{} = kept, %AgentID{} = id, opts) do
    define(
      kept,
      id,
      [fields: Keyword.fetch!(opts, :definition), source: {:api, Keyword.fetch!(opts, :token)}] ++
        Keyword.take(opts, [:held, :host])
    )
  end

  @doc """
  Reads the definition `:fields` of the agent `id`, written by `:source`, on
  `:host`, keeps it with the hooks it is `:held` to, none unless given,
  routes its notices, and answers the spec it writes, not yet held to them.
  """
  @spec define(t(), AgentID.t(),
          fields: map(),
          source: WardrikDefinition.source(),
          held: [Wardrik.Hook.t()],
          host: Wardrik.Host.t()
        ) :: {:ok, Spec.t()} | {:error, String.t()}
  def define(%__MODULE__{} = kept, %AgentID{} = id, opts) do
    {host, opts} = Keyword.pop!(opts, :host)
    context = context(kept, id)

    with {:ok, record} <- Record.define(context, id, opts),
         {:ok, spec} <- Record.spec(record, id, context: context, host: host) do
      :ok = keep(kept, record)
      :ok = route(kept)
      {:ok, spec}
    end
  end

  @doc """
  The definition kept for the agent `id`, as it was sent, with the tools it
  names that offer nothing yet on `:host`; see `WardrikDefinition.missing/3`.
  """
  @spec get(t(), AgentID.t(), host: Wardrik.Host.t()) ::
          {:ok, Wardrik.Definition.Read.t()} | {:error, :not_found}
  def get(%__MODULE__{store: store} = kept, %AgentID{} = id, opts) do
    with {:ok, record} <- Record.get(store, id) do
      fields = Record.fields(record)

      missing =
        WardrikDefinition.missing(fields, record.id,
          context: context(kept, record.id),
          host: Keyword.fetch!(opts, :host)
        )

      {:ok, %Wardrik.Definition.Read{fields: fields, missing: missing}}
    end
  end

  @doc "Forgets the definition kept for the agent `id`, or `{:error, :not_found}`."
  @spec delete(t(), AgentID.t()) :: :ok | {:error, :not_found}
  def delete(%__MODULE__{store: store} = kept, %AgentID{} = id) do
    with {:ok, _record} <- Record.get(store, id), do: drop(kept, id)
  end

  @doc """
  Sets the trigger `name` of the definition kept for the agent `id` to the
  `:fields` given, and brings its triggers to it: whether it was added or
  changed, and the trigger as `WardrikTrigger.encode/1` writes it.
  """
  @spec put_trigger(t(), AgentID.t(), String.t(), fields: map()) ::
          {:ok, :created | :changed, map()} | {:error, :not_found} | {:error, String.t()}
  def put_trigger(%__MODULE__{store: store} = kept, %AgentID{} = id, name, opts) do
    with {:ok, record} <- Record.get(store, id),
         {:ok, record, status, trigger} <-
           Record.put_trigger(record, name,
             trigger: Keyword.fetch!(opts, :fields),
             context: context(kept, id)
           ) do
      :ok = keep(kept, record)
      {:ok, status, WardrikTrigger.encode(trigger)}
    end
  end

  @doc """
  Deletes the trigger `name` of the definition kept for the agent `id`, and
  stops it: the trigger it was, as `put_trigger/4` answers one.
  """
  @spec delete_trigger(t(), AgentID.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def delete_trigger(%__MODULE__{store: store} = kept, %AgentID{} = id, name) do
    with {:ok, record} <- Record.get(store, id),
         trigger =
           Enum.find(Record.triggers(record, context: context(kept, id)), &(&1.name == name)),
         {:ok, record} <- Record.delete_trigger(record, name),
         :ok <- keep(kept, record),
         do: {:ok, WardrikTrigger.encode(trigger)}
  end

  @doc """
  The spec the definition kept for `id`, or for the agent it is a
  conversation of, writes now on `:host`, or `:none` where none is kept or
  it does not build.
  """
  @spec current(t(), AgentID.t(), host: Wardrik.Host.t()) :: {:ok, Spec.t()} | :none
  def current(%__MODULE__{store: store} = kept, %AgentID{} = id, opts) do
    with {:ok, record} <- Record.of(store, id),
         {:ok, spec} <- build(kept, record, id, opts) do
      {:ok, spec}
    else
      _none -> :none
    end
  end

  @doc "The agents `pattern` covers a definition is kept for, read from the store's keys alone."
  @spec defined(t(), Resource.t()) :: [AgentID.t()]
  def defined(%__MODULE__{store: store}, pattern),
    do: for(id <- Record.ids(store), Resource.covers?(pattern, AgentID.resource(id)), do: id)

  @doc """
  Builds every agent awake on `:host` again from the definition it runs on,
  and puts the routes again. Why an agent does not build is logged.
  """
  @spec reload(t(), host: Wardrik.Host.t()) :: :ok
  def reload(%__MODULE__{} = kept, opts) do
    only = fn _record, _id -> true end

    for message <- rebuild(kept, host: Keyword.fetch!(opts, :host), only: only),
        do: Logger.error(message)

    route(kept)
  end

  @doc "This node, whose `reload/2` reads the records every node shares."
  @spec reloading(t()) :: [node()]
  def reloading(%__MODULE__{}), do: [node()]

  @doc """
  The spec `record` writes for the agent `id`, its own or one of its
  conversations, under the context of its owner on `:host`, held to the
  hooks it was defined under and the policy of the token that sent it, where
  one did.
  """
  @spec build(t(), Record.t(), AgentID.t(), host: Wardrik.Host.t()) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def build(%__MODULE__{} = kept, %Record{} = record, %AgentID{} = id, opts) do
    with {:ok, spec} <- Record.spec(record, id, [context: context(kept, record.id)] ++ opts),
         do: {:ok, %{spec | hooks: record.held ++ List.wrap(spec.hooks)}}
  end

  @doc """
  Builds every agent awake on `:host` that `:only` picks again, given the
  record it runs on and its ID, from the definition kept; why each that
  does not build does not, a message each. One asleep takes its definition
  as it wakes.
  """
  @spec rebuild(t(), host: Wardrik.Host.t(), only: (Record.t(), AgentID.t() -> boolean())) ::
          [String.t()]
  def rebuild(%__MODULE__{store: store} = kept, opts) do
    host = Keyword.fetch!(opts, :host)
    only = Keyword.fetch!(opts, :only)

    for %{id: id, asleep: false} <- Fleet.list(Resource.parse!("*"), host: host),
        {:ok, record} <- [Record.of(store, id)],
        only.(record, id),
        message <- rebuilt(kept, record, id, host),
        do: message
  end

  defp rebuilt(kept, record, id, host) do
    with {:ok, spec} <- build(kept, record, id, host: host),
         {:ok, _pid} <- Fleet.put(spec) do
      []
    else
      {:error, message} when is_binary(message) ->
        ["#{id} does not build from its definition: #{message}"]

      {:error, reason} ->
        ["#{id} did not start: #{inspect(reason)}"]
    end
  end

  @doc """
  Keeps `record`, and brings its agent's triggers to those it lists. A
  trigger starts only once the definition listing it is kept.
  """
  @spec keep(t(), Record.t()) :: :ok
  def keep(%__MODULE__{store: store} = kept, %Record{} = record) do
    :ok = Record.put(store, record)
    WardrikTrigger.sync(record.id, Record.triggers(record, context: context(kept, record.id)))
  end

  @doc "Forgets the definition kept for the agent `id`, the triggers it lists and its route."
  @spec drop(t(), AgentID.t()) :: :ok
  def drop(%__MODULE__{store: store} = kept, %AgentID{} = id) do
    :ok = WardrikTrigger.sync(id, [])
    :ok = Record.delete(store, id)
    route(kept)
  end

  @doc """
  The route of each agent a kept definition routes. A definition whose
  `notify` no longer reads, as one naming a target the context no longer
  has, routes nothing.
  """
  @spec routes(t()) :: %{AgentID.t() => WardrikNotify.Route.t()}
  def routes(%__MODULE__{store: store} = kept) do
    for %Record{id: id} = record <- Record.all(store),
        {:ok, route} <- [Record.route(record, context: context(kept, id))],
        into: %{},
        do: {id, route}
  end

  @doc "Puts `routes/1` to `WardrikNotify` on this node, then on every node `:nodes` gives."
  @spec route(t()) :: :ok
  def route(%__MODULE__{nodes: nodes} = kept) do
    routes = routes(kept)
    :ok = WardrikNotify.put_routes(routes)
    :erpc.multicast(nodes.(), WardrikNotify, :put_routes, [routes])
  end

  defp context(%__MODULE__{contexts: contexts}, id),
    do: Contexts.context(contexts, AgentID.put_external_id(id, nil))
end

defimpl Wardrik.Definition, for: WardrikDefinition.Kept do
  use Wardrik.Definition.None

  defdelegate put(kept, id, opts), to: WardrikDefinition.Kept
  defdelegate get(kept, id, opts), to: WardrikDefinition.Kept
  defdelegate delete(kept, id), to: WardrikDefinition.Kept
  defdelegate put_trigger(kept, id, name, opts), to: WardrikDefinition.Kept
  defdelegate delete_trigger(kept, id, name), to: WardrikDefinition.Kept
  defdelegate current(kept, id, opts), to: WardrikDefinition.Kept
  defdelegate defined(kept, pattern), to: WardrikDefinition.Kept
  defdelegate reload(kept, opts), to: WardrikDefinition.Kept
  defdelegate reloading(kept), to: WardrikDefinition.Kept
end
