defmodule Tars.LLM.Turn.Parked do
  @moduledoc """
  A turn stopped part way through, waiting on a person.

  When a `Tars.Hook` asks about a call, the call does not run and the
  conversation is not advanced: an assistant message asking for tools with no
  results behind it is not a conversation any provider will accept. So the turn
  stops and hands back everything needed to pick it up again — the context as
  it stood, the response that asked, each `Tars.Call` in the batch as it came
  out, and how many iterations were left.

  `Tars.Agent` holds one of these and answers `Tars.Agent.resume/2` with it.
  Nothing else has to understand its shape.

      {:parked, parked} = Tars.LLM.Turn.run(scope, context)
      Tars.LLM.Turn.Parked.calls(parked)
      #=> [{%{id: "call_1", name: "deploy", arguments: %{}}, "This ships to production."}]

  A turn can also stop before a model call, when a hook asks about it. Then
  there is no response yet, and the one call waiting is the model call
  itself, named `model`, so a person answers it the way they answer any other.

  Every call is held as it is written down, with no scope.

  `:revision` is the `Tars.Hook.revision/1` of the hooks the turn parked
  under.

  A parked turn holds no credentials and runs no processes. It is waiting, and
  waiting costs nothing.
  """

  alias Tars.Call
  alias Tars.LLM.ToolRunner
  alias Tars.Tool

  @enforce_keys [:context, :response, :outcomes, :acc, :remaining, :revision]
  defstruct [:context, :response, :outcomes, :acc, :remaining, :revision]

  @typedoc "Everything needed to finish a turn that stopped to ask."
  @type t() :: %__MODULE__{
          context: ReqLLM.Context.t(),
          response: ReqLLM.Response.t() | nil,
          outcomes: [Call.t()],
          acc: [ReqLLM.Message.t()],
          remaining: non_neg_integer() | :infinity,
          revision: String.t()
        }

  @typedoc "What a person is being asked to decide, per call."
  @type decision() :: :approve | {:deny, String.t()}

  @doc """
  A turn parked before `call`, a model call waiting on a person.

  `fields` are the rest of the struct's: `:context`, `:acc`, `:remaining` and
  `:revision`. Raises on one missing, or on a key the struct does not have.
  """
  @spec model(Call.t(), keyword()) :: t()
  def model(%Call{target: %Call.Model{}, state: :waiting} = call, fields) when is_list(fields),
    do: struct!(__MODULE__, [response: nil, outcomes: [Call.under(call, nil)]] ++ fields)

  @doc "Whether the turn stopped before a model call rather than at a tool call."
  @spec model?(t()) :: boolean()
  def model?(%__MODULE__{response: nil}), do: true
  def model?(%__MODULE__{}), do: false

  @doc "The calls still waiting, each with the prompt a person is shown."
  @spec calls(t()) :: [{Tool.call(), String.t()}]
  def calls(%__MODULE__{outcomes: outcomes}), do: ToolRunner.parked(outcomes)

  @doc "Whether anything is still waiting."
  @spec waiting?(t()) :: boolean()
  def waiting?(%__MODULE__{outcomes: outcomes}), do: ToolRunner.parked(outcomes) != []
end
