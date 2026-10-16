defmodule Wardrik.Operations.Cancel do
  @moduledoc """
  Drops what an agent is doing, and what is queued behind it: the turn it is
  taking, or the calls it waits on a person for. An agent taking no turn is
  left as it is, and nothing is recorded; see
  `Wardrik.Operations.Cancelling`. The answer is the agents it stopped.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Fleet
  alias Wardrik.Operations.Cancelling

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :message

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id} = request, _caller) do
    case Fleet.lookup(id) do
      nil -> {:error, AgentOperation.not_found(id)}
      member -> {:ok, Change.new(request, Cancelling.of([member], id))}
    end
  end

  @impl Wardrik.Command
  def make(%Change{effect: %Cancelling{} = effect}, _caller) do
    made = Cancelling.make(effect)
    {:ok, made.agents, made}
  end

  @impl Wardrik.Command
  def render(agents), do: Wardrik.Resource.cancelled(agents)
end
