defmodule Wardrik.Operations.Decide do
  @moduledoc """
  Approves or rejects calls an agent waits on, as the caller's principal: one
  or more of the calls it is parked on, taken together.

  A caller who reaches the agent, with a grant that allows `:read` on it,
  may ask; the agent takes the decisions from one whose grant allows
  `:decide` on it, or who asked for the turn that waits, and answers anyone
  else `:forbidden`. See `Wardrik.Agent.decide/3`.

  `new/2` reads decisions as `wardrik_protocol`'s `decisions.json` describes
  them: each the `id` of a call, `approve` with a `note` for the agent where
  one is given, or `reject` with a `reason`. The answer lists each call with
  what was decided, `approved` or `rejected`.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Agent
  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Error

  @enforce_keys [:agent, :decisions]
  defstruct [:agent, :decisions]

  @type decision() :: :approve | {:approve, String.t()} | {:deny, String.t()}

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          decisions: %{String.t() => decision()}
        }

  @refused "A person refused this call."

  @doc "The request to decide what `body` says for the agent `agent`, or why it does not read."
  @spec new(Wardrik.AgentID.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Wardrik.AgentID{} = agent, %{"decisions" => [_ | _] = decisions}) do
    read =
      Enum.reduce_while(decisions, {:ok, %{}}, fn decision, {:ok, read} ->
        case decision(decision) do
          {:ok, id, decided} -> {:cont, {:ok, Map.put(read, id, decided)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    with {:ok, decisions} <- read, do: {:ok, %__MODULE__{agent: agent, decisions: decisions}}
  end

  def new(_agent, _body), do: invalid("decisions is a list of a call's id and its decision")

  defp decision(%{"id" => id, "decision" => "approve"} = decision) when is_binary(id) do
    case decision["note"] do
      note when is_binary(note) and note != "" -> {:ok, id, {:approve, note}}
      _none -> {:ok, id, :approve}
    end
  end

  defp decision(%{"id" => id, "decision" => "reject"} = decision) when is_binary(id) do
    case decision["reason"] do
      reason when is_binary(reason) and reason != "" -> {:ok, id, {:deny, reason}}
      _none -> {:ok, id, {:deny, @refused}}
    end
  end

  defp decision(_decision), do: invalid("Each decision is a call's id, and approve or reject")

  defp invalid(message), do: {:error, Error.new(:invalid, message)}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :read

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: agent, decisions: decisions}} = change, caller) do
    case Agent.decide(agent, decisions, caller) do
      :ok ->
        {:ok, %{"decisions" => Enum.map(Enum.sort(decisions), &decided/1)}, change.effect}

      {:error, :not_found} ->
        {:error, AgentOperation.not_found(agent)}

      {:error, :not_parked} ->
        {:error, Error.new(:conflict, "#{agent} is not waiting on anything.")}

      {:error, :stale_decision} ->
        {:error, Error.new(:conflict, "#{agent} is not waiting on #{named(decisions)}.")}

      {:error, :forbidden} ->
        {:error,
         Error.new(
           :forbidden,
           "This caller may not decide the calls of #{agent}, and did not ask for the turn " <>
             "that waits."
         )}

      {:error, :unrecorded} ->
        {:error,
         Error.new(:unavailable, "#{agent} could not record the decision, so it was not taken.")}
    end
  end

  defp decided({id, decision}), do: %{"id" => id, "decision" => verdict(decision)}

  defp verdict(:approve), do: "approved"
  defp verdict({:approve, _note}), do: "approved"
  defp verdict({:deny, _reason}), do: "rejected"

  defp named(decisions) do
    case decisions |> Map.keys() |> Enum.sort() do
      [only] -> only
      ids -> "#{Enum.join(Enum.drop(ids, -1), ", ")} and #{List.last(ids)}"
    end
  end

  @doc false
  @spec deciding({String.t(), decision()}) :: map()
  def deciding({id, :approve}), do: %{"id" => id, "decision" => "approve"}
  def deciding({id, {:approve, note}}), do: %{"id" => id, "decision" => "approve", "note" => note}

  def deciding({id, {:deny, reason}}),
    do: %{"id" => id, "decision" => "reject", "reason" => reason}

  defimpl Wardrik.Effect do
    alias Wardrik.Operations.Decide

    def preview(%{agent: agent, decisions: decisions}) do
      %{
        "deciding" => %{
          "agent" => to_string(agent),
          "decisions" => Enum.map(Enum.sort(decisions), &Decide.deciding/1)
        }
      }
    end

    def audit(_decide), do: []
  end
end
