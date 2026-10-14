defmodule Wardrik.Operations.Forget do
  @moduledoc """
  Removes an agent, with everything it had, and the definition the host's
  `Wardrik.Definition` keeps of it, which may refuse; see
  `Wardrik.Operations.Forgetting`. The agent is forgotten where one is kept,
  awake or asleep, or a definition of it is.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Definition
  alias Wardrik.Error
  alias Wardrik.Fleet
  alias Wardrik.Operations.Forgetting

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id} = request, caller) do
    if Fleet.stored?(id) or Definition.kept?(caller.host, id) do
      case Forgetting.of(caller.host, [id], id) do
        %Forgetting{kept: [{^id, why}]} -> {:error, Error.new(:conflict, why)}
        effect -> {:ok, Change.new(request, effect)}
      end
    else
      {:error, AgentOperation.not_found(id)}
    end
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id}, effect: effect}, caller) do
    case Definition.forget(caller.host, id) do
      {:error, :conflict, why} ->
        {:error, Error.new(:conflict, why)}

      {:ok, kept} ->
        running = Fleet.lookup(id)
        if running, do: :ok = Fleet.forget(id)

        if running || kept,
          do: {:ok, Forgetting.answer(effect, []), effect},
          else: {:error, AgentOperation.not_found(id)}
    end
  end
end
