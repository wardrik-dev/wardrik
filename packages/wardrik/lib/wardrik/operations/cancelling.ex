defmodule Wardrik.Operations.Cancelling do
  @moduledoc """
  The effect of a cancel: the agents it stops, those taking a turn or
  waiting on a person as it was planned, and what was asked, one agent or a
  prefix. An agent with no turn going is left as it is, and nothing is
  recorded of it.
  """

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Fleet.Member

  @enforce_keys [:agents, :asked]
  defstruct [:agents, :asked]

  @type t() :: %__MODULE__{agents: [AgentID.t()], asked: AgentID.t() | Prefix.t()}

  @doc "The effect of cancelling `asked`, which reaches `members`: those of them taking a turn."
  @spec of([Member.t()], AgentID.t() | Prefix.t()) :: t()
  def of(members, asked) do
    %__MODULE__{
      agents: for(%Member{id: id} = member <- members, busy?(member), do: id),
      asked: asked
    }
  end

  defp busy?(%Member{status: status}), do: status != :idle

  @doc "Cancels each agent `effect` stops, and answers those it stopped."
  @spec make(t()) :: t()
  def make(%__MODULE__{agents: agents} = effect),
    do: %{effect | agents: Enum.filter(agents, &(Agent.interrupt(&1) == :ok))}

  @doc "What a cancel answers once made: the agents it stopped."
  @spec answer(t()) :: map()
  def answer(%__MODULE__{agents: agents}), do: %{"cancelled" => Enum.map(agents, &to_string/1)}

  defimpl Wardrik.Effect do
    def preview(%{agents: agents}), do: %{"cancelling" => Enum.map(agents, &to_string/1)}

    def audit(%{agents: agents, asked: %Prefix{} = prefix}),
      do: for(id <- agents, do: {:agent_cancelled, id, prefix})

    def audit(%{agents: agents}), do: for(id <- agents, do: {:agent_cancelled, id})
  end
end
