defmodule WardrikDaemon.Definition do
  @moduledoc """
  What an agent is, as it was written, kept in the store under the agent's
  ID: an agent file's frontmatter, with its body as `instructions`, or the
  body of `PUT /v1/agents/{id}`.

  `WardrikDaemon.AgentFile.spec/3` builds the agent's `Wardrik.Agent.Spec`
  from one, and whatever says what an agent is reads it here: `wardrik show`
  and `wardrik ls`, `GET /v1/agents/{id}/definition`, and a surface starting
  an agent through `WardrikDaemon.Agents.options/1`, on any node.

  An agent with an external ID has no definition of its own. It is one
  conversation of the agent without one, and runs on that agent's
  definition: `acme/books/1696.1234` is `acme/books`, in a thread of its
  own. `of/1` finds the definition an agent runs on.
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
  @spec put(t()) :: :ok
  def put(%__MODULE__{id: %AgentID{external_id: nil} = id} = definition) do
    {:ok, _vsn} = WardrikStore.put(@ns, to_string(id), definition)
    :ok
  end

  @doc "The definition kept for the agent `id`."
  @spec get(AgentID.t()) :: {:ok, t()} | {:error, :not_found}
  def get(%AgentID{} = id) do
    case WardrikStore.get(@ns, to_string(id)) do
      %__MODULE__{} = definition -> {:ok, definition}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The definition the agent `id` runs on: its own, or, for an ID with an
  external ID, that of the agent without one.
  """
  @spec of(AgentID.t()) :: {:ok, t()} | {:error, :not_found}
  def of(%AgentID{} = id), do: id |> AgentID.put_external_id(nil) |> get()

  @doc "Every definition kept."
  @spec all() :: [t()]
  def all do
    for key <- WardrikStore.keys(@ns, ""),
        %__MODULE__{} = definition <- [WardrikStore.get(@ns, key)],
        do: definition
  end

  @doc "Forgets the definition kept for the agent `id`, if there is one."
  @spec delete(AgentID.t()) :: :ok
  def delete(%AgentID{} = id), do: :ok = WardrikStore.delete(@ns, to_string(id))
end
