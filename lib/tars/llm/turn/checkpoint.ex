defmodule Tars.LLM.Turn.Checkpoint do
  @moduledoc """
  A turn as it stood just before running a batch of tool calls: the context,
  the response that asked for them, the messages the turn had produced, and the
  iterations it had left.

  A turn under a scope with a journal hands one of these over before every
  batch, and runs nothing until the journal has it. `Tars.LLM.Turn.replay/2`
  carries a turn on from one, with the same calls and the same ids, so a
  `Tars.Ledger` can say which of them already ran.

  Like `Tars.LLM.Turn.Parked`, it holds no credentials and no processes.
  """

  @enforce_keys [:context, :response, :acc, :remaining]
  defstruct [:context, :response, :acc, :remaining]

  @type t() :: %__MODULE__{
          context: ReqLLM.Context.t(),
          response: ReqLLM.Response.t(),
          acc: [ReqLLM.Message.t()],
          remaining: non_neg_integer() | :infinity
        }

  @doc "The ids of the calls the checkpointed response asked for."
  @spec call_ids(t()) :: [String.t()]
  def call_ids(%__MODULE__{response: response}) do
    %{tool_calls: calls} = ReqLLM.Response.classify(response)
    Enum.map(calls, & &1.id)
  end
end
