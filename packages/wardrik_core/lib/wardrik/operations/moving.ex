defmodule Wardrik.Operations.Moving do
  @moduledoc """
  The effect of moving an agent to another node: where it runs, or
  `:asleep`, where it goes, and what moving it interrupts, as it was planned:
  a turn it is taking, or the calls it waits on a person for. An agent on
  the node already stays as it is.
  """

  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member

  @enforce_keys [:agent, :from, :to, :status]
  defstruct [:agent, :from, :to, :status]

  @type t() :: %__MODULE__{
          agent: AgentID.t(),
          from: node() | :asleep,
          to: node(),
          status: Member.status()
        }

  @doc "The effect of moving `member` to the node `to`."
  @spec of(Member.t(), node()) :: t()
  def of(%Member{id: id, asleep: true, status: status}, to),
    do: %__MODULE__{agent: id, from: :asleep, to: to, status: status}

  def of(%Member{id: id, node: node, status: status}, to),
    do: %__MODULE__{agent: id, from: node, to: to, status: status}

  @doc "Moves the agent, where it is not on the node already, or why it did not move."
  @spec make(t()) :: {:ok, t()} | {:error, Error.t()}
  def make(%__MODULE__{from: to, to: to} = effect), do: {:ok, effect}

  def make(%__MODULE__{agent: id, to: to} = effect) do
    case Fleet.move(id, to) do
      {:ok, _pid} ->
        {:ok, effect}

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{id} did not move to #{to}: #{inspect(reason)}")}
    end
  end

  defimpl Wardrik.Effect do
    def preview(%{agent: id, from: from, to: to, status: status}) do
      moving =
        %{"agent" => to_string(id), "to" => to_string(to)}
        |> put("from", from != :asleep && to_string(from))
        |> put("interrupting", from != to && interrupting(status))

      %{"moving" => moving}
    end

    defp interrupting(:running), do: "turn"
    defp interrupting(:parked), do: "calls"
    defp interrupting(:idle), do: false

    defp put(map, _key, false), do: map
    defp put(map, key, value), do: Map.put(map, key, value)

    def audit(%{from: to, to: to}), do: []
    def audit(%{agent: id, to: to}), do: [{:agent_moved, id, to}]
  end
end
