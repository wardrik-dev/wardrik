defmodule Wardrik.Agent.Snapshot do
  @moduledoc """
  What a client attaching to an agent reads in one call: the conversation so
  far, what the agent is doing, what it is waiting on, and the identity that
  tells a saved view from a stale one.

      %Wardrik.Agent.Snapshot{} = Wardrik.Agent.snapshot(~A"acme/@jon/assistant", host: host)

  `agent` is the agent's ID. `generation` changes when an agent is
  forgotten and started again under the same key, and survives a restart.
  `trace_id` is the current turn's, or `nil` between turns. `sequence` is
  the last event its `Wardrik.Event.Log` has written, for a client to read
  and follow the log from. `labels` are what its history holds, as
  `Wardrik.Label`s, which every turn carries until the history is cleared.
  """

  alias Wardrik.Agent.State

  @enforce_keys [
    :agent,
    :generation,
    :status,
    :context,
    :parked,
    :trace_id,
    :outcome,
    :sequence,
    :labels
  ]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          generation: String.t(),
          status: Wardrik.Agent.State.View.status(),
          context: ReqLLM.Context.t(),
          parked: [{Wardrik.Tool.call(), String.t()}],
          trace_id: String.t() | nil,
          outcome: State.outcome(),
          sequence: non_neg_integer(),
          labels: [Wardrik.Label.t()]
        }
end
