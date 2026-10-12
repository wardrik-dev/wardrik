defmodule Wardrik.Operations.Cancel do
  @moduledoc """
  Drops what an agent is doing, and what is queued behind it.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Agent
  alias Wardrik.AgentOperation
  alias Wardrik.Change

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :message

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id} = request, _caller),
    do: {:ok, Change.new(request, [{:agent_cancelled, id}])}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id}}, _caller) do
    case Agent.interrupt(id) do
      :ok -> {:ok, %{"agent" => %{"id" => to_string(id)}}}
      {:error, :not_found} -> {:error, AgentOperation.not_found(id)}
    end
  end
end
