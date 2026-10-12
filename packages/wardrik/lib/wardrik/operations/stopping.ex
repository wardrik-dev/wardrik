defmodule Wardrik.Operations.Stopping do
  @moduledoc """
  The effect of stopping agents: those awake as it was planned, each synced
  and stopped so it sleeps as it was, keeping its conversation, until
  something asks it again. An agent asleep already is left as it is.
  """

  alias Wardrik.AgentID
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member

  @enforce_keys [:agents]
  defstruct [:agents]

  @type t() :: %__MODULE__{agents: [AgentID.t()]}

  @doc "The effect of stopping `members`: those of them awake."
  @spec of([Member.t()]) :: t()
  def of(members),
    do: %__MODULE__{agents: for(%Member{id: id, asleep: false} <- members, do: id)}

  @doc "Stops each agent `effect` names, and answers those it stopped."
  @spec make(t()) :: t()
  def make(%__MODULE__{agents: agents} = effect),
    do: %{effect | agents: Enum.filter(agents, &(Fleet.stop(&1) == :ok))}

  @doc "What a stop answers once made: the agents it stopped."
  @spec answer(t()) :: map()
  def answer(%__MODULE__{agents: agents}), do: %{"stopped" => Enum.map(agents, &to_string/1)}

  defimpl Wardrik.Effect do
    def preview(%{agents: agents}), do: %{"stopping" => Enum.map(agents, &to_string/1)}
    def audit(%{agents: agents}), do: for(id <- agents, do: {:agent_stopped, id})
  end
end
