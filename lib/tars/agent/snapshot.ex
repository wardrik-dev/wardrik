defmodule Tars.Agent.Snapshot do
  @moduledoc """
  What a client attaching to an agent reads in one call: the conversation so
  far, what the agent is doing, what it is waiting on, and the identity that
  tells a saved view from a stale one.

      %Tars.Agent.Snapshot{} = Tars.Agent.snapshot("acme/jon/assistant")

  `generation` changes when an agent is forgotten and started again under the
  same key, and survives a restart. `trace_id` is the current turn's, or `nil`
  between turns.
  """

  alias Tars.Agent.State
  alias Tars.Delegation

  @enforce_keys [:generation, :status, :context, :parked, :trace_id, :delegations, :outcome]
  defstruct [:generation, :status, :context, :parked, :trace_id, :delegations, :outcome]

  @type t() :: %__MODULE__{
          generation: String.t(),
          status: State.status(),
          context: ReqLLM.Context.t(),
          parked: [{Tars.Tool.call(), String.t()}],
          trace_id: String.t() | nil,
          delegations: Delegation.t(),
          outcome: State.outcome()
        }
end
