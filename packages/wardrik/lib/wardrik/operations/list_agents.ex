defmodule Wardrik.Operations.ListAgents do
  @moduledoc """
  Every agent under a prefix, awake or asleep, as `Wardrik.Resource.agent/1`
  shapes each, sorted by ID. A caller whose grant does not allow `:read`
  under the prefix is refused, not shown an empty list.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Query

  alias Wardrik.Fleet
  alias Wardrik.Resource

  @enforce_keys [:prefix]
  defstruct [:prefix]

  @type t() :: %__MODULE__{prefix: Wardrik.AgentID.Prefix.t()}

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{prefix: prefix}), do: prefix

  @impl Wardrik.FleetOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{prefix: prefix}, _caller),
    do: {:ok, %{"agents" => Enum.map(Fleet.list(prefix), &Resource.agent/1)}}
end
