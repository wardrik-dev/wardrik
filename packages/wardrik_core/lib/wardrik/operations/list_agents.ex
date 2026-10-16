defmodule Wardrik.Operations.ListAgents do
  @moduledoc """
  Every agent under a prefix, awake or asleep, as the fleet lists each, a
  `Wardrik.Fleet.Member`, sorted by ID. A caller whose grant does not allow `:read`
  under the prefix is refused, not shown an empty list.
  """

  @behaviour Wardrik.Catalog.Entry
  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Query

  alias Wardrik.Fleet
  alias Wardrik.Resource

  @enforce_keys [:prefix]
  defstruct [:prefix]

  @type t() :: %__MODULE__{prefix: Wardrik.AgentID.Prefix.t()}

  @impl Wardrik.Catalog.Entry
  def name, do: "agents.list"

  @impl Wardrik.Catalog.Entry
  def summary,
    do: "List the agents within reach, awake or asleep, with what each is doing."

  @impl Wardrik.Catalog.Entry
  def input, do: WardrikProtocol.schema("input_agents_list")

  @impl Wardrik.Catalog.Entry
  def new(%Wardrik.AgentID.Prefix{} = prefix, _input), do: {:ok, %__MODULE__{prefix: prefix}}

  @impl Wardrik.Catalog.Entry
  def labels(_answer), do: []

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{prefix: prefix}), do: prefix

  @impl Wardrik.FleetOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{prefix: prefix}, _caller), do: {:ok, Fleet.list(prefix)}

  @impl Wardrik.Query
  def render(members), do: %{"agents" => Enum.map(members, &Resource.agent/1)}
end
