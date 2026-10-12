defmodule Wardrik.Operations.Decide do
  @moduledoc """
  Approves or rejects a call an agent waits on, as the caller's principal.

  `new/3` reads a decision as `wardrik_protocol` describes one: `approve`,
  with a `note` for the agent where one is given, or `reject`, with a
  `reason`.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Agent
  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Error

  @enforce_keys [:agent, :interrupt, :decision]
  defstruct [:agent, :interrupt, :decision]

  @type decision() :: :approve | {:approve, String.t()} | {:deny, String.t()}

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          interrupt: String.t(),
          decision: decision()
        }

  @doc "The request to decide `interrupt`, which the agent `agent` waits on, or why it does not read."
  @spec new(Wardrik.AgentID.t(), String.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Wardrik.AgentID{} = agent, interrupt, body) when is_binary(interrupt) do
    with {:ok, decision} <- decision(body),
         do: {:ok, %__MODULE__{agent: agent, interrupt: interrupt, decision: decision}}
  end

  defp decision(%{"decision" => "approve"} = body) do
    case body["note"] do
      note when is_binary(note) -> {:ok, {:approve, note}}
      _none -> {:ok, :approve}
    end
  end

  defp decision(%{"decision" => "reject"} = body) do
    case body["reason"] do
      reason when is_binary(reason) and reason != "" -> {:ok, {:deny, reason}}
      _none -> {:ok, {:deny, "Refused, with no reason given."}}
    end
  end

  defp decision(_body), do: {:error, Error.new(:invalid, "decision is approve or reject")}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :decide

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{} = request}, caller) do
    %__MODULE__{agent: agent, interrupt: interrupt, decision: decision} = request

    case Agent.decide(agent, %{interrupt => decision}, by: caller.principal) do
      :ok ->
        {:ok, %{"interrupt" => %{"id" => interrupt, "decision" => verdict(decision)}}}

      {:error, :not_found} ->
        {:error, AgentOperation.not_found(agent)}

      {:error, :not_parked} ->
        {:error, Error.new(:conflict, "#{agent} is not waiting on anything.")}

      {:error, :stale_decision} ->
        {:error, Error.new(:conflict, "#{agent} is not waiting on #{interrupt}.")}

      {:error, :unrecorded} ->
        {:error,
         Error.new(:unavailable, "#{agent} could not record the decision, so it was not taken.")}
    end
  end

  defp verdict(:approve), do: "approved"
  defp verdict({:approve, _note}), do: "approved"
  defp verdict({:deny, _reason}), do: "rejected"
end
