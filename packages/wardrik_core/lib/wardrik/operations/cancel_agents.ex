defmodule Wardrik.Operations.CancelAgents do
  @moduledoc """
  Drops what every agent under a prefix is doing, and what is queued behind
  it: each agent taking a turn, or waiting on a person, as it is planned.
  The agents stay up; see `Wardrik.Operations.Cancelling`. The answer is
  the agents it stopped.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Fleet
  alias Wardrik.Operations.Cancelling

  @enforce_keys [:prefix]
  defstruct [:prefix]

  @type t() :: %__MODULE__{prefix: Wardrik.AgentID.Prefix.t()}

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{prefix: prefix}), do: prefix

  @impl Wardrik.FleetOperation
  def action, do: :message

  @impl Wardrik.Command
  def plan(%__MODULE__{prefix: prefix} = request, _caller),
    do: {:ok, Change.new(request, Cancelling.of(Fleet.list(prefix), prefix))}

  @impl Wardrik.Command
  def make(%Change{effect: %Cancelling{} = effect}, _caller) do
    made = Cancelling.make(effect)
    {:ok, made.agents, made}
  end

  @impl Wardrik.Command
  def render(agents), do: Wardrik.Resource.cancelled(agents)
end
