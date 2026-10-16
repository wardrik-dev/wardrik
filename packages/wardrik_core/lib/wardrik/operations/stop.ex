defmodule Wardrik.Operations.Stop do
  @moduledoc """
  Stops an agent now, keeping its conversation: it sleeps as it was until
  something asks it again, or it is started; see
  `Wardrik.Operations.Stopping`. One asleep already is left as it is.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Fleet
  alias Wardrik.Operations.Stopping

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id} = request, _caller) do
    case Fleet.lookup(id) do
      nil -> {:error, AgentOperation.not_found(id)}
      member -> {:ok, Change.new(request, Stopping.of([member]))}
    end
  end

  @impl Wardrik.Command
  def make(%Change{effect: %Stopping{} = effect}, _caller) do
    made = Stopping.make(effect)
    {:ok, Stopping.answer(made), made}
  end
end
