defmodule Tars.LLM.Turn.Parked do
  @moduledoc """
  A turn stopped part way through, waiting on a person.

  When a policy answers `{:ask, prompt}`, the call does not run and the
  conversation is not advanced: an assistant message asking for tools with no
  results behind it is not a conversation any provider will accept. So the turn
  stops and hands back everything needed to pick it up again — the context as
  it stood, the response that asked, what the other calls in the batch did, and
  how many iterations were left.

  `Tars.Agent` holds one of these and answers `Tars.Agent.resume/2` with it.
  Nothing else has to understand its shape.

      {:parked, parked} = Tars.LLM.Turn.run(scope, context)
      Tars.LLM.Turn.Parked.calls(parked)
      #=> [{%{id: "call_1", name: "deploy", arguments: %{}}, "This ships to production."}]

  A parked turn holds no credentials and runs no processes. It is waiting, and
  waiting costs nothing.
  """

  alias Tars.LLM.ToolRunner
  alias Tars.Tool

  @enforce_keys [:context, :response, :outcomes, :acc, :remaining]
  defstruct [:context, :response, :outcomes, :acc, :remaining]

  @typedoc "Everything needed to finish a turn that stopped to ask."
  @type t() :: %__MODULE__{
          context: ReqLLM.Context.t(),
          response: ReqLLM.Response.t(),
          outcomes: [ToolRunner.outcome()],
          acc: [ReqLLM.Message.t()],
          remaining: pos_integer() | :infinity
        }

  @typedoc "What a person is being asked to decide, per call."
  @type decision() :: :approve | {:deny, String.t()}

  @doc false
  @spec new(
          ReqLLM.Context.t(),
          ReqLLM.Response.t(),
          [ToolRunner.outcome()],
          [ReqLLM.Message.t()],
          pos_integer() | :infinity
        ) :: t()
  def new(context, response, outcomes, acc, remaining) do
    %__MODULE__{
      context: context,
      response: response,
      outcomes: outcomes,
      acc: acc,
      remaining: remaining
    }
  end

  @doc "The calls still waiting, each with the prompt a person is shown."
  @spec calls(t()) :: [{Tool.call(), String.t()}]
  def calls(%__MODULE__{outcomes: outcomes}), do: ToolRunner.parked(outcomes)

  @doc "Whether anything is still waiting."
  @spec waiting?(t()) :: boolean()
  def waiting?(%__MODULE__{outcomes: outcomes}) do
    Enum.any?(outcomes, &match?({:parked, _call, _prompt}, &1))
  end
end
