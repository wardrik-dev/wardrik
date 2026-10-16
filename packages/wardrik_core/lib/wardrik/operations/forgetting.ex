defmodule Wardrik.Operations.Forgetting do
  @moduledoc """
  The effect of a forget: the agents it removes, with everything each had,
  the agents it keeps, each with why, as one an agent file declares, and
  what was asked, one agent or a prefix.

  The host's `Wardrik.Definition` is asked of each agent: it says which it
  keeps as the forget is planned, through `Wardrik.Definition.editable/2`,
  and forgets the definition of each removed, where it keeps one.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Fleet
  alias Wardrik.Host

  @enforce_keys [:agents, :kept, :asked]
  defstruct [:agents, :kept, :asked]

  @type t() :: %__MODULE__{
          agents: [AgentID.t()],
          kept: [{AgentID.t(), String.t()}],
          asked: AgentID.t() | Prefix.t()
        }

  @doc """
  The effect of forgetting `ids`, under `asked`: those `host` lets go, and
  why it keeps the rest.
  """
  @spec of(Host.t(), [AgentID.t()], AgentID.t() | Prefix.t()) :: t()
  def of(host, ids, asked) do
    definitions = Host.definitions(host)

    {agents, kept} =
      Enum.reduce(ids, {[], []}, fn id, {agents, kept} ->
        case Definition.editable(definitions, id) do
          :ok -> {[id | agents], kept}
          {:error, :conflict, why} -> {agents, [{id, why} | kept]}
        end
      end)

    %__MODULE__{agents: Enum.reverse(agents), kept: Enum.reverse(kept), asked: asked}
  end

  @doc """
  Forgets each agent `effect` removes, and the definition `host` keeps of
  it: the effect it made, and each agent that could not be forgotten, with
  why. An agent the host refuses now is kept, as the plan would have.
  """
  @spec make(Host.t(), t()) :: {t(), [{AgentID.t(), String.t()}]}
  def make(host, %__MODULE__{agents: agents, kept: kept} = effect) do
    forgotten = Enum.map(agents, &{&1, forget(host, &1)})

    made = %{
      effect
      | agents: for({id, :ok} <- forgotten, do: id),
        kept: kept ++ for({id, {:kept, why}} <- forgotten, do: {id, why})
    }

    {made, for({id, {:failed, why}} <- forgotten, do: {id, why})}
  end

  defp forget(host, id) do
    with {:ok, _kept} <- Definitions.forget(host, id),
         :ok <- Fleet.forget(id) do
      :ok
    else
      {:error, :conflict, why} -> {:kept, why}
      {:error, reason} -> {:failed, inspect(reason)}
    end
  end

  @typedoc "What became of an agent a forget reached."
  @type outcome() :: :forgotten | {:kept, String.t()} | {:failed, String.t()}

  @doc """
  What a forget answers once made: each agent it reached, by ID, with what
  became of it: removed, kept with why, or not removed with why.
  """
  @spec answer(t(), [{AgentID.t(), String.t()}]) :: %{AgentID.t() => outcome()}
  def answer(%__MODULE__{agents: agents, kept: kept}, failed) do
    Map.new(
      Enum.map(agents, &{&1, :forgotten}) ++
        for({id, why} <- kept, do: {id, {:kept, why}}) ++
        for({id, why} <- failed, do: {id, {:failed, why}})
    )
  end

  defimpl Wardrik.Effect do
    alias Wardrik.Resource

    def preview(%{agents: agents, kept: kept}),
      do: %{"forgetting" => Enum.map(agents, &to_string/1), "keeping" => Resource.reasons(kept)}

    def audit(%{agents: agents, asked: %Prefix{} = prefix}),
      do: for(id <- agents, do: {:agent_forgotten, id, prefix})

    def audit(%{agents: agents}), do: for(id <- agents, do: {:agent_forgotten, id})
  end
end
