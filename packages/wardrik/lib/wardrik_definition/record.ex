defmodule WardrikDefinition.Record do
  @moduledoc """
  What an agent is, as it was written, kept in the store under the agent's
  ID: an agent file's frontmatter, with its body as `instructions`, the body
  of `PUT /v1/agents/{id}`, or a host's defaults.

  `spec/3` builds the agent's `Wardrik.Agent.Spec` from one under a
  `WardrikDefinition.Context`, and `triggers/2` and `route/2` read what is
  kept beside the spec. The store functions are each handed first the store
  records are kept in.

  An agent with an external ID has no record of its own. It is one
  conversation of the agent without one, and runs on that agent's record:
  `acme/books/1696.1234` is `acme/books`, in a thread of its own. `of/2`
  finds the record an agent runs on.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias WardrikDefinition.Context

  @ns :definitions

  @enforce_keys [:id, :fields, :source]
  defstruct [:id, :fields, :source]

  @type t() :: %__MODULE__{
          id: AgentID.t(),
          fields: WardrikDefinition.fields(),
          source: WardrikDefinition.source()
        }

  @doc """
  The record the definition `:fields` writes for the agent `id`, written by
  `:source`. What its settings say is checked as `spec/3` builds a spec from
  it, the trees its workspace shares against the scope of a grant that sent
  it among them.
  """
  @spec define(Context.t(), AgentID.t(), fields: map(), source: WardrikDefinition.source()) ::
          {:ok, t()} | {:error, String.t()}
  def define(%Context{} = context, %AgentID{} = id, opts) do
    fields = Keyword.fetch!(opts, :fields)

    with :ok <- WardrikDefinition.accept(id, fields, context),
         do: {:ok, %__MODULE__{id: id, fields: fields, source: Keyword.fetch!(opts, :source)}}
  end

  @doc """
  The spec `record` writes for the agent `id`, its own or one of its
  conversations, under `:context`; see `WardrikDefinition.spec/5`.
  """
  @spec spec(t(), AgentID.t(), context: Context.t()) :: {:ok, Spec.t()} | {:error, String.t()}
  def spec(%__MODULE__{id: owner, fields: fields, source: source}, %AgentID{} = id, opts),
    do: WardrikDefinition.spec(fields, owner, id, Keyword.fetch!(opts, :context), source)

  @doc """
  Where the notices of `record`'s agent go, under `:context`; see
  `WardrikDefinition.route/3`.
  """
  @spec route(t(), context: Context.t()) ::
          {:ok, WardrikNotify.Route.t()} | :none | {:error, String.t()}
  def route(%__MODULE__{id: id, fields: fields}, opts),
    do: WardrikDefinition.route(fields, id, Keyword.fetch!(opts, :context))

  @doc "The definition as the HTTP API writes one; see `WardrikDefinition.fields/1`."
  @spec fields(t()) :: map()
  def fields(%__MODULE__{fields: fields}), do: WardrikDefinition.fields(fields)

  @doc "The triggers `record` lists, read under `:context`; see `WardrikDefinition.triggers/2`."
  @spec triggers(t(), context: Context.t()) :: [WardrikTrigger.trigger()]
  def triggers(%__MODULE__{fields: fields}, opts),
    do: WardrikDefinition.triggers(fields, Keyword.fetch!(opts, :context))

  @doc """
  `record` with the trigger `name` set to the `:trigger` given, read under
  `:context`; see `WardrikDefinition.put_trigger/3`.
  """
  @spec put_trigger(t(), String.t(), trigger: map(), context: Context.t()) ::
          {:ok, t(), :created | :changed, WardrikTrigger.trigger()} | {:error, String.t()}
  def put_trigger(%__MODULE__{fields: fields} = record, name, opts) do
    with {:ok, fields, status, trigger} <- WardrikDefinition.put_trigger(fields, name, opts),
         do: {:ok, %{record | fields: fields}, status, trigger}
  end

  @doc "`record` without the trigger `name`, or `{:error, :not_found}` where it has none."
  @spec delete_trigger(t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def delete_trigger(%__MODULE__{fields: fields} = record, name) do
    with {:ok, fields} <- WardrikDefinition.delete_trigger(fields, name),
         do: {:ok, %{record | fields: fields}}
  end

  @doc "Keeps `record` in `store`, in place of any its agent had."
  @spec put(WardrikStore.t(), t()) :: :ok
  def put(store, %__MODULE__{id: %AgentID{external_id: nil} = id} = record) do
    {:ok, _vsn} = WardrikStore.put(store, @ns, to_string(id), record)
    :ok
  end

  @doc "The record kept for the agent `id`."
  @spec get(WardrikStore.t(), AgentID.t()) :: {:ok, t()} | {:error, :not_found}
  def get(store, %AgentID{} = id) do
    case WardrikStore.get(store, @ns, to_string(id)) do
      %__MODULE__{} = record -> {:ok, record}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The record the agent `id` runs on: its own, or, for an ID with an external
  ID, that of the agent without one.
  """
  @spec of(WardrikStore.t(), AgentID.t()) :: {:ok, t()} | {:error, :not_found}
  def of(store, %AgentID{} = id), do: get(store, AgentID.put_external_id(id, nil))

  @doc "The ID of every agent a record is kept for, read from the keys alone."
  @spec ids(WardrikStore.t()) :: [AgentID.t()]
  def ids(store), do: store |> WardrikStore.keys(@ns) |> Enum.map(&AgentID.parse!/1)

  @doc "Every record kept."
  @spec all(WardrikStore.t()) :: [t()]
  def all(store) do
    for key <- WardrikStore.keys(store, @ns),
        %__MODULE__{} = record <- [WardrikStore.get(store, @ns, key)],
        do: record
  end

  @doc "Forgets the record kept for the agent `id`, if there is one."
  @spec delete(WardrikStore.t(), AgentID.t()) :: :ok
  def delete(store, %AgentID{} = id), do: :ok = WardrikStore.delete(store, @ns, to_string(id))
end
