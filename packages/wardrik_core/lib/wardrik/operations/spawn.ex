defmodule Wardrik.Operations.Spawn do
  @moduledoc """
  Starts an agent wherever the fleet puts it: one asleep wakes, one the
  host defines starts on its definition, and one nothing defines yet is
  defined as the host's `c:Wardrik.Definition.create/1` says; see
  `Wardrik.Operations.Spawning`. Starting one on a node of the caller's
  choosing is `Wardrik.Operations.SpawnOn`.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Operations.Spawning

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id} = request, caller) do
    with {:ok, effect} <- Spawning.of(caller.host, id, :anywhere),
         do: {:ok, Change.new(request, effect)}
  end

  @impl Wardrik.Command
  def make(%Change{effect: %Spawning{} = effect}, caller) do
    with {:ok, made} <- Spawning.make(caller.host, effect), do: {:ok, Spawning.answer(made), made}
  end

  @impl Wardrik.Command
  def render(spawned), do: Wardrik.Resource.spawned(spawned)
end
