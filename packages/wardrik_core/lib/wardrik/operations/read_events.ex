defmodule Wardrik.Operations.ReadEvents do
  @moduledoc """
  A page of an agent's log: up to `limit` events after the sequence number
  `starting_after`, oldest first. Where the log was trimmed past it, the error is
  a `:gap` whose `details` hold `oldest`, the first event still kept.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Query

  alias Wardrik.Error
  alias Wardrik.Event.Log

  @enforce_keys [:agent, :limit]
  defstruct [:agent, :limit, starting_after: 0]

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          starting_after: non_neg_integer(),
          limit: pos_integer()
        }

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{agent: id, starting_after: starting_after, limit: limit}, caller) do
    store = Wardrik.Host.store(caller.host)

    case Log.read(store, id, starting_after: starting_after, limit: limit) do
      {:ok, events} -> {:ok, %{"events" => events}}
      {:gap, oldest} -> {:error, gap(oldest)}
    end
  end

  @doc "The error for events asked for before `oldest`, the first a log still keeps."
  @spec gap(pos_integer()) :: Error.t()
  def gap(oldest) do
    Error.new(
      :gap,
      "Events before #{oldest} have been dropped; read the snapshot and follow from its sequence.",
      %{"oldest" => oldest}
    )
  end
end
