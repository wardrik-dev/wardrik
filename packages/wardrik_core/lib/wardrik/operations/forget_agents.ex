defmodule Wardrik.Operations.ForgetAgents do
  @moduledoc """
  Removes every agent under a prefix, with everything each had, but those
  the host's `Wardrik.Definition` keeps, each with why; see
  `Wardrik.Operations.Forgetting`. A prefix with nothing under it is not
  found, and one whose every agent is kept is a conflict saying why.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Error
  alias Wardrik.Fleet
  alias Wardrik.Operations.Forgetting

  @enforce_keys [:prefix]
  defstruct [:prefix]

  @type t() :: %__MODULE__{prefix: Wardrik.AgentID.Prefix.t()}

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{prefix: prefix}), do: prefix

  @impl Wardrik.FleetOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{prefix: prefix} = request, caller) do
    case Forgetting.of(caller.host, Enum.map(Fleet.list(prefix), & &1.id), prefix) do
      %Forgetting{agents: [], kept: []} ->
        {:error, Error.new(:not_found, "Nothing runs under #{prefix}.")}

      %Forgetting{agents: [], kept: kept} ->
        {:error, Error.new(:conflict, Enum.map_join(kept, "\n", &elem(&1, 1)))}

      effect ->
        {:ok, Change.new(request, effect)}
    end
  end

  @impl Wardrik.Command
  def make(%Change{effect: %Forgetting{} = effect}, caller) do
    {made, failed} = Forgetting.make(caller.host, effect)
    {:ok, Forgetting.answer(made, failed), made}
  end
end
