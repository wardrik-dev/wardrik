defmodule WardrikDaemon.Definition do
  @moduledoc """
  What an agent is, as it was written, kept in the store under the agent's
  ID: an agent file's frontmatter, with its body as `instructions`, or the
  body of `PUT /v1/agents/{id}`.

  `WardrikDaemon.AgentFile.spec/3` builds the agent's `Wardrik.Agent.Spec`
  from one, and whatever says what an agent is reads it here: `wardrik show`
  and `wardrik ls`, `GET /v1/agents/{id}/definition`, and a surface starting
  an agent through `WardrikDaemon.Agents.options/2`, on any node. Each
  function is handed first the store definitions are kept in.

  An agent with an external ID has no definition of its own. It is one
  conversation of the agent without one, and runs on that agent's
  definition: `acme/books/1696.1234` is `acme/books`, in a thread of its
  own. `of/2` finds the definition an agent runs on.
  """

  alias Wardrik.AgentID

  @ns :definitions

  @enforce_keys [:id, :fields, :source]
  defstruct [:id, :fields, :source]

  @typedoc """
  Where a definition was written: an agent file, by its name, or the HTTP
  API, with the grant of the token that sent it, or `nil` for `config.yaml`'s
  `defaults`, which no token sent.
  """
  @type source() :: {:file, String.t()} | {:api, Wardrik.Grant.t() | nil}

  @type t() :: %__MODULE__{
          id: AgentID.t(),
          fields: %{String.t() => term()},
          source: source()
        }

  @doc "Keeps `definition`, in place of any its agent had."
  @spec put(WardrikStore.t(), t()) :: :ok
  def put(store, %__MODULE__{id: %AgentID{external_id: nil} = id} = definition) do
    {:ok, _vsn} = WardrikStore.put(store, @ns, to_string(id), definition)
    :ok
  end

  @doc "The definition kept for the agent `id`."
  @spec get(WardrikStore.t(), AgentID.t()) :: {:ok, t()} | {:error, :not_found}
  def get(store, %AgentID{} = id) do
    case WardrikStore.get(store, @ns, to_string(id)) do
      %__MODULE__{} = definition -> {:ok, definition}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The definition the agent `id` runs on: its own, or, for an ID with an
  external ID, that of the agent without one.
  """
  @spec of(WardrikStore.t(), AgentID.t()) :: {:ok, t()} | {:error, :not_found}
  def of(store, %AgentID{} = id), do: get(store, AgentID.put_external_id(id, nil))

  @doc "Every definition kept."
  @spec all(WardrikStore.t()) :: [t()]
  def all(store) do
    for key <- WardrikStore.keys(store, @ns),
        %__MODULE__{} = definition <- [WardrikStore.get(store, @ns, key)],
        do: definition
  end

  @doc "Forgets the definition kept for the agent `id`, if there is one."
  @spec delete(WardrikStore.t(), AgentID.t()) :: :ok
  def delete(store, %AgentID{} = id), do: :ok = WardrikStore.delete(store, @ns, to_string(id))
end
