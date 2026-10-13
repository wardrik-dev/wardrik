defmodule Wardrik.Operations.ReadDefinition do
  @moduledoc """
  The definition last put for an agent, as it was sent, where the host's
  `Wardrik.Definition` keeps them.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Catalog.Entry
  @behaviour Wardrik.Query

  alias Wardrik.Definition
  alias Wardrik.Error

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t()}

  @impl Wardrik.Catalog.Entry
  def name, do: "agent.definition.read"

  @impl Wardrik.Catalog.Entry
  def summary,
    do: "Read the agent's definition as it was last put: its instructions, tools and triggers."

  @impl Wardrik.Catalog.Entry
  def input, do: WardrikProtocol.schema("input_agent_definition_read")

  @impl Wardrik.Catalog.Entry
  def new(%Wardrik.AgentID{} = agent, _input), do: {:ok, %__MODULE__{agent: agent}}

  @impl Wardrik.Catalog.Entry
  def labels(_answer), do: []

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{agent: id}, _caller) do
    with {:ok, module} <- Definition.module(:get),
         {:ok, definition} <- module.get(id) do
      {:ok, definition}
    else
      :unsupported ->
        {:error, Error.new(:unsupported, "This server does not keep agents' definitions.")}

      {:error, :not_found} ->
        {:error, undefined(id)}
    end
  end

  @doc "The error for the agent `id`, where no definition of it is kept."
  @spec undefined(Wardrik.AgentID.t()) :: Error.t()
  def undefined(id), do: Error.new(:not_found, "#{id} has no definition kept.")
end
