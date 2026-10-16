defmodule Wardrik.Operations.ReadAudit do
  @moduledoc """
  A page of `Wardrik.Audit`, what people changed across the deployment: up
  to `limit` changes after the sequence number `starting_after`, oldest
  first, each a `Wardrik.Event.Log.Entry`. Where the log was trimmed past it, the error is a `:gap`, as
  `Wardrik.Operations.ReadEvents` answers for an agent's log.
  """

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Query

  alias Wardrik.Deployment
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Operations.ReadEvents

  @enforce_keys [:limit]
  defstruct [:limit, starting_after: 0]

  @type t() :: %__MODULE__{starting_after: non_neg_integer(), limit: pos_integer()}

  @impl Wardrik.DeploymentOperation
  def subject(_request), do: Deployment.new()

  @impl Wardrik.DeploymentOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{starting_after: starting_after, limit: limit}, caller) do
    store = Wardrik.Host.store(caller.host)

    case Log.read(store, :audit, starting_after: starting_after, limit: limit) do
      {:ok, changes} -> {:ok, Entry.numbered(changes, starting_after)}
      {:gap, oldest} -> {:error, ReadEvents.gap(oldest)}
    end
  end

  @impl Wardrik.Query
  def render(entries), do: %{"changes" => Enum.map(entries, & &1.event)}
end
