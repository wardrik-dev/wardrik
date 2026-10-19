defmodule Wardrik.Definitions do
  @moduledoc """
  Where agents' definitions are kept, as the host's `:definitions`: each a
  `Wardrik.Definition`, kept in `:store` under its agent's ID, and read
  under the `WardrikDefinition.Context` that `:contexts` give the agent's
  owner (see `WardrikDefinition.Contexts`).

      definitions = %Wardrik.Definitions{store: store, contexts: Wardrik.context([])}
      host = Wardrik.Host.new(store: store, definitions: definitions)

  `Wardrik` reads a definition with `Wardrik.Definition.read/2` under
  `context/2`, and keeps it with `put/2`. As an agent starts or wakes it
  asks the host's `Wardrik.Specs`, which these definitions are, for the
  spec it runs on, `spec/2`, so a definition kept while it slept is the one
  it wakes with.

  An agent file declares the agents whose definitions came from it: `put/2`
  refuses to keep any other over one of them, and `editable/2` says so
  before an agent is changed or forgotten.

  A definition's `triggers` are its agent's, brought to what it lists as it
  is kept, with `WardrikTrigger.sync/2`, so a host that keeps definitions
  starts `WardrikTrigger`. Where its notices go is put to `WardrikNotify`
  on this node and on every node `:nodes` gives as a definition is kept or
  forgotten, so an agent is routed wherever it runs; a node not running
  `WardrikNotify.Supervisor` routes nothing.

  An agent with an external ID has no definition of its own. It is one
  conversation of the agent without one, and runs on that agent's
  definition: `acme/books/1696.1234` is `acme/books`, in a thread of its
  own.
  """

  require Logger

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Fleet
  alias Wardrik.Resource
  alias WardrikDefinition.Contexts

  @ns :definitions

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

  @doc "The context the definition of the agent `id`, or of its owner, is read under."
  @spec context(t(), AgentID.t()) :: WardrikDefinition.Context.t()
  def context(%__MODULE__{contexts: contexts}, %AgentID{} = id),
    do: Contexts.context(contexts, owner(id))

  @doc """
  Keeps `definition`, in place of any its agent had, brings its agent's
  triggers to those it lists, and routes its notices. One that came from
  no agent file is refused in place of one that did.
  """
  @spec put(t(), Definition.t()) :: :ok | {:error, :conflict, String.t()}
  def put(%__MODULE__{store: store} = definitions, %Definition{id: id} = definition) do
    with :ok <- writable(definitions, definition) do
      {:ok, _vsn} = WardrikStore.put(store, @ns, to_string(id), definition)
      :ok = WardrikTrigger.sync(id, definition.triggers)
      route(definitions)
    end
  end

  defp writable(_definitions, %Definition{source: {:file, _path}}), do: :ok
  defp writable(definitions, %Definition{id: id}), do: editable(definitions, id)

  @doc "The definition kept for the agent `id`."
  @spec get(t(), AgentID.t()) :: {:ok, Definition.t()} | {:error, :not_found}
  def get(%__MODULE__{store: store}, %AgentID{} = id) do
    case WardrikStore.get(store, @ns, to_string(id)) do
      %Definition{} = definition -> {:ok, definition}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Forgets the definition kept for the agent `id`, the triggers it lists and
  its route, or `{:error, :not_found}` where none is kept.
  """
  @spec delete(t(), AgentID.t()) :: :ok | {:error, :not_found}
  def delete(%__MODULE__{store: store} = definitions, %AgentID{} = id) do
    with {:ok, _definition} <- get(definitions, id) do
      :ok = WardrikTrigger.sync(id, [])
      :ok = WardrikStore.delete(store, @ns, to_string(id))
      route(definitions)
    end
  end

  @doc "Every definition kept for an agent `pattern` covers, sorted by ID."
  @spec list(t(), Resource.t()) :: [Definition.t()]
  def list(%__MODULE__{} = definitions, pattern) do
    for id <- ids(definitions, pattern),
        {:ok, definition} <- [get(definitions, id)],
        do: definition
  end

  @doc "The agents `pattern` covers a definition is kept for, sorted, read from the store's keys alone."
  @spec ids(t(), Resource.t()) :: [AgentID.t()]
  def ids(%__MODULE__{store: store}, pattern) do
    for key <- Enum.sort(WardrikStore.keys(store, @ns)),
        id = AgentID.parse!(key),
        Resource.covers?(pattern, AgentID.resource(id)),
        do: id
  end

  @doc """
  The spec the agent `id` runs on now: that the definition kept for it, or
  for the agent it is a conversation of, writes under its owner's context
  on the `:host` given, whose tools, sources and runtimes it names; see
  `Wardrik.Definition.spec/3`. `{:error, :not_found}` where none is kept,
  and a message where it does not build.
  """
  @spec spec(t(), AgentID.t(), host: Wardrik.Host.t()) ::
          {:ok, Spec.t()} | {:error, :not_found} | {:error, String.t()}
  def spec(%__MODULE__{} = definitions, %AgentID{} = id, opts) do
    with {:ok, definition} <- get(definitions, owner(id)),
         do:
           Definition.spec(definition, id,
             context: context(definitions, id),
             host: Keyword.fetch!(opts, :host)
           )
  end

  @doc """
  `:ok` where the agent `id` may be changed or forgotten by anything but its
  agent file, or a conflict naming the file that declares it.
  """
  @spec editable(t(), AgentID.t()) :: :ok | {:error, :conflict, String.t()}
  def editable(%__MODULE__{} = definitions, %AgentID{} = id) do
    case get(definitions, id) do
      {:ok, %Definition{source: {:file, path}}} ->
        {:error, :conflict,
         "#{id} is declared by #{shown(path)}; change or remove that file, then reload it"}

      _other ->
        :ok
    end
  end

  defp shown(path), do: Path.join(path |> Path.dirname() |> Path.basename(), Path.basename(path))

  @doc """
  Sets the trigger `name` of the definition kept for the agent `id` to
  `fields`, and brings its triggers to it: whether it was added or changed,
  and the trigger as `WardrikTrigger.encode/1` writes it.
  """
  @spec put_trigger(t(), AgentID.t(), String.t(), map()) ::
          {:ok, :created | :changed, map()}
          | {:error, :not_found}
          | {:error, String.t()}
          | {:error, :conflict, String.t()}
  def put_trigger(%__MODULE__{} = definitions, %AgentID{} = id, name, fields) do
    with :ok <- editable(definitions, id),
         {:ok, definition} <- get(definitions, id),
         {:ok, definition, status, trigger} <-
           Definition.put_trigger(definition, name, fields, context(definitions, id)),
         :ok <- put(definitions, definition),
         do: {:ok, status, WardrikTrigger.encode(trigger)}
  end

  @doc """
  Deletes the trigger `name` of the definition kept for the agent `id`, and
  stops it: the trigger it was, as `put_trigger/4` answers one.
  """
  @spec delete_trigger(t(), AgentID.t(), String.t()) ::
          {:ok, map()}
          | {:error, :not_found}
          | {:error, String.t()}
          | {:error, :conflict, String.t()}
  def delete_trigger(%__MODULE__{} = definitions, %AgentID{} = id, name) do
    with :ok <- editable(definitions, id),
         {:ok, definition} <- get(definitions, id),
         {:ok, definition, trigger} <-
           Definition.delete_trigger(definition, name, context(definitions, id)),
         :ok <- put(definitions, definition),
         do: {:ok, WardrikTrigger.encode(trigger)}
  end

  @doc """
  The tools `definition` names that offer nothing yet, under its agent's
  owner's context on the `:host` given; see `Wardrik.Definition.missing/2`.
  """
  @spec missing(t(), Definition.t(), host: Wardrik.Host.t()) :: [String.t()]
  def missing(%__MODULE__{} = definitions, %Definition{id: id} = definition, opts),
    do:
      Definition.missing(definition,
        context: context(definitions, id),
        host: Keyword.fetch!(opts, :host)
      )

  @doc """
  Has the contexts read again what they are read from, then builds every
  agent awake on `:host` again, as `rebuild/2` does: the nodes the contexts
  were read on. Why an agent does not build is logged.
  """
  @spec reload(t(), host: Wardrik.Host.t()) :: [node()]
  def reload(%__MODULE__{contexts: contexts} = definitions, opts) do
    nodes = Contexts.reload(contexts, opts)
    for message <- rebuild(definitions, opts), do: Logger.error(message)
    nodes
  end

  @doc """
  Builds every agent awake on `:host` a definition is kept for again, from
  it, and puts the routes again: why each that does not build does not, a
  message each. One asleep takes its definition as it wakes.
  """
  @spec rebuild(t(), host: Wardrik.Host.t()) :: [String.t()]
  def rebuild(%__MODULE__{} = definitions, opts) do
    host = Keyword.fetch!(opts, :host)

    messages =
      for %{id: id, asleep: false} <- Fleet.list(Resource.parse!("*"), host: host),
          message <- rebuilt(definitions, id, host),
          do: message

    :ok = route(definitions)
    messages
  end

  defp rebuilt(definitions, id, host) do
    with {:ok, spec} <- spec(definitions, id, host: host),
         {:ok, _pid} <- Fleet.put(spec) do
      []
    else
      {:error, :not_found} ->
        []

      {:error, message} when is_binary(message) ->
        ["#{id} does not build from its definition: #{message}"]

      {:error, reason} ->
        ["#{id} did not start: #{inspect(reason)}"]
    end
  end

  @doc "Where the notices of each agent whose definition routes them go."
  @spec routes(t()) :: %{AgentID.t() => WardrikNotify.Route.t()}
  def routes(%__MODULE__{} = definitions) do
    for %Definition{id: id, notify: %WardrikNotify.Route{} = route} <-
          list(definitions, Resource.parse!("*")),
        into: %{},
        do: {id, route}
  end

  @doc "Puts `routes/1` to `WardrikNotify` on this node, then on every node `:nodes` gives."
  @spec route(t()) :: :ok
  def route(%__MODULE__{nodes: nodes} = definitions) do
    routes = routes(definitions)
    :ok = WardrikNotify.put_routes(routes)
    :erpc.multicast(nodes.(), WardrikNotify, :put_routes, [routes])
  end

  defp owner(id), do: AgentID.put_external_id(id, nil)
end

defimpl Wardrik.Specs, for: Wardrik.Definitions do
  def current(definitions, id, opts) do
    case Wardrik.Definitions.spec(definitions, id, opts) do
      {:ok, spec} -> {:ok, spec}
      {:error, _none} -> :none
    end
  end

  defdelegate defined(definitions, pattern), to: Wardrik.Definitions, as: :ids
end
