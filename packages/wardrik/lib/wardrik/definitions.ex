defmodule Wardrik.Definitions do
  @moduledoc """
  Where agents' definitions are kept, as the host's `:definitions`: each a
  `Wardrik.Definition`, kept in `:store` under its agent's resource name,
  and read under the `WardrikDefinition.Context` that `:contexts` give the
  agent's owner (see `WardrikDefinition.Contexts`).

      definitions = %Wardrik.Definitions{store: store, contexts: Wardrik.context([])}
      host = Wardrik.Host.new(store: store, definitions: definitions)

  `Wardrik` reads a definition with `Wardrik.Definition.read/2` under
  `context/2`, and keeps it with `put/2`. As an agent starts or wakes it
  asks the host's `Wardrik.Specs`, which these definitions are, for the
  spec it runs on, `spec/3`, so a definition kept while it slept is the one
  it wakes with.

  An agent file declares the agents whose definitions came from it: `put/2`
  refuses to keep any other over one of them, and `editable/2` says so
  before an agent is changed or forgotten.

  A definition's `triggers` are its agent's, brought to what it lists as it
  is kept, with `WardrikTrigger.sync/2`, so a host that keeps definitions
  starts `WardrikTrigger`. Where its notices go, its `notify`, is read by
  `WardrikNotify` as each event comes, so a definition kept is routed as it
  is from its next event.

  A `Wardrik.Thread` has no definition of its own: it runs on its agent's,
  so `acme/books/1696.1234` is `acme/books`, in a thread of its own.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentAddress
  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Fleet
  alias Wardrik.Resource
  alias WardrikDefinition.Contexts

  @ns :definitions

  @enforce_keys [:store, :contexts]
  defstruct [:store, :contexts]

  @typedoc "Definitions kept in `:store`, each read under what `:contexts` gives its agent's owner."
  @type t() :: %__MODULE__{store: WardrikStore.t(), contexts: Contexts.t()}

  @doc "The context the definition of the agent `id` is read under: its owner's."
  @spec context(t(), AgentID.t()) :: WardrikDefinition.Context.t()
  def context(%__MODULE__{contexts: contexts}, %AgentID{} = id),
    do: Contexts.context(contexts, Resource.owner(AgentID.resource(id)))

  @doc """
  Keeps `definition`, in place of any its agent had, and brings its agent's
  triggers to those it lists. One that came from no agent file is refused
  in place of one that did.
  """
  @spec put(t(), Definition.t()) :: :ok | {:error, :conflict, String.t()}
  def put(%__MODULE__{store: store} = definitions, %Definition{id: id} = definition) do
    with :ok <- writable(definitions, definition) do
      {:ok, _vsn} = WardrikStore.put(store, @ns, key(id), definition)
      :ok = WardrikTrigger.sync(id, definition.triggers)
    end
  end

  defp writable(_definitions, %Definition{source: {:file, _path}}), do: :ok
  defp writable(definitions, %Definition{id: id}), do: editable(definitions, id)

  @doc "The definition kept for the agent `id`; a `Wardrik.Thread` has none."
  @spec get(t(), AgentAddress.t()) :: {:ok, Definition.t()} | {:error, :not_found}
  def get(%__MODULE__{store: store}, id) do
    case WardrikStore.get(store, @ns, key(id)) do
      %Definition{} = definition -> {:ok, definition}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Forgets the definition kept for the agent `id`, and the triggers it lists,
  or `{:error, :not_found}` where none is kept.
  """
  @spec delete(t(), AgentAddress.t()) :: :ok | {:error, :not_found}
  def delete(%__MODULE__{store: store} = definitions, id) do
    with {:ok, _definition} <- get(definitions, id) do
      :ok = WardrikTrigger.sync(id, [])
      :ok = WardrikStore.delete(store, @ns, key(id))
    end
  end

  @doc "Every definition kept for an agent `pattern` covers, in the order of their names."
  @spec list(t(), Resource.t()) :: [Definition.t()]
  def list(%__MODULE__{} = definitions, pattern) do
    for id <- ids(definitions, pattern),
        {:ok, definition} <- [get(definitions, id)],
        do: definition
  end

  @doc """
  The agents `pattern` covers a definition is kept for, in the order of
  their names, read from the store's keys alone.
  """
  @spec ids(t(), Resource.t()) :: [AgentID.t()]
  def ids(%__MODULE__{store: store}, pattern) do
    for key <- Enum.sort(WardrikStore.keys(store, @ns, Resource.prefix(pattern))),
        resource = Resource.parse!(key),
        Resource.covers?(pattern, resource),
        {:ok, id} = Resource.address(resource),
        do: id
  end

  defp key(id), do: to_string(AgentAddress.resource(id))

  @doc """
  The spec the agent `id` runs on now: that the definition kept for it
  writes under its owner's context on the `:host` given, whose tools,
  sources and runtimes it names; see `Wardrik.Definition.spec/2`.
  `{:error, :not_found}` where none is kept, and a message where it does
  not build.
  """
  @spec spec(t(), AgentID.t(), host: Wardrik.Host.t()) ::
          {:ok, Spec.t()} | {:error, :not_found} | {:error, String.t()}
  def spec(%__MODULE__{} = definitions, %AgentID{} = id, opts) do
    with {:ok, definition} <- get(definitions, id),
         do:
           Definition.spec(definition,
             context: context(definitions, id),
             host: Keyword.fetch!(opts, :host)
           )
  end

  @doc """
  `:ok` where the agent `id` may be changed or forgotten by anything but its
  agent file, or a conflict naming the file that declares it.
  """
  @spec editable(t(), AgentAddress.t()) :: :ok | {:error, :conflict, String.t()}
  def editable(%__MODULE__{} = definitions, id) do
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
  Reads the definitions of the agents `:resources` covers again, in one
  pass on this node, and builds those awake on `:host` again. Answers the
  agents read, and why each file, definition or agent failed.

    * `:host` - the `Wardrik.Host` the agents run on
    * `:resources` - `Wardrik.Resource` patterns, as `acme/*`; every agent
      by default

  What the contexts' files declare now is kept. A definition no file
  declares any more is retired: its agent stops and keeps its
  conversation. Every other is read again under its owner's context. A
  file that doesn't read keeps what it declared, and is reported whatever
  `:resources` covers.
  """
  @spec reload(t(), keyword()) :: %{reloaded: [AgentID.t()], failed: [String.t()]}
  def reload(%__MODULE__{contexts: contexts} = definitions, opts) do
    opts = Keyword.validate!(opts, [:host, resources: [Resource.parse!("*")]])
    {host, patterns} = {Keyword.fetch!(opts, :host), opts[:resources]}
    files = Contexts.reload(contexts, host: host)

    declared =
      for {_path, {:ok, definition}} <- files,
          Enum.any?(patterns, &Resource.covers?(&1, AgentAddress.resource(definition.id))),
          into: %{},
          do: {definition.id, definition}

    unread = for {path, {:error, _message}} <- files, do: path
    kept = patterns |> Enum.flat_map(&list(definitions, &1)) |> Enum.uniq_by(& &1.id)

    for %Definition{id: id, source: {:file, path}} <- kept,
        not is_map_key(declared, id) and path not in unread,
        do: :ok = retire(definitions, id)

    read = Enum.map(Map.values(declared), &{:ok, &1}) ++ read_again(definitions, kept, declared)
    for {:ok, definition} <- read, do: :ok = put(definitions, definition)

    %{
      reloaded: Enum.sort_by(for({:ok, %Definition{id: id}} <- read, do: id), &to_string/1),
      failed:
        for({_path, {:error, message}} <- files, do: message) ++
          for({:error, message} <- read, do: message) ++
          rebuild(definitions, patterns, host)
    }
  end

  # Every definition no file declares, read again under its owner's context.
  defp read_again(definitions, kept, declared) do
    for %Definition{id: id, source: source} = definition <- kept,
        not match?({:file, _path}, source) and not is_map_key(declared, id) do
      with {:error, message} <- Definition.again(definition, context(definitions, id)),
           do: {:error, "#{id} does not read: #{message}"}
    end
  end

  defp retire(definitions, id) do
    :ok = delete(definitions, id)

    case Fleet.stop(id) do
      :ok -> :ok
      {:error, :noproc} -> :ok
    end
  end

  # Builds every agent awake on `host` that `patterns` cover, and a
  # definition is kept for, again: why each that does not build does not.
  defp rebuild(definitions, patterns, host) do
    awake = patterns |> Enum.flat_map(&Fleet.list(&1, host: host)) |> Enum.uniq_by(& &1.id)

    for %{id: id, asleep: false} <- awake,
        message <- rebuilt(definitions, id, host),
        do: message
  end

  defp rebuilt(definitions, id, host) do
    with {:ok, spec} <- spec(definitions, AgentAddress.agent(id), host: host),
         {:ok, _pid} <- Fleet.put(%{spec | id: id}) do
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
