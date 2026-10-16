defmodule Wardrik.LLM.Retry do
  @moduledoc """
  The seam that decides whether a model call that failed is asked again, and
  after how long.

  A turn whose model call fails hands the request, with the failed try added
  to its `attempts` (see `Wardrik.LLM.Attempt`), to the scope's retry. Asked
  again, the request goes through the hooks and the `Wardrik.LLM.Dispatch`
  as the first try did, under a message id of its own, so what the failed
  try had streamed is never taken for the answer.

  Deciding whether to ask again is the retry's; deciding what the next try
  is, such as another model, is the dispatch's, from the attempts it is
  handed. Failing over is the two together:

      defmodule MyApp.Failover do
        defstruct [:models]
      end

      defimpl Wardrik.LLM.Dispatch, for: MyApp.Failover do
        def admit(_failover, %Request{attempts: []} = request, _opts), do: {:ok, request}

        def admit(failover, %Request{attempts: attempts} = request, _opts) do
          case Enum.at(failover.models, length(attempts)) do
            nil -> {:error, :no_model_left}
            model -> {:ok, Request.put_model(request, model)}
          end
        end

        def settle(_failover, _request, _opts), do: :ok
      end

  Without a retry on the scope, `Wardrik.LLM.Retry.Backoff` asks again after
  each wait the config's `:retries` lists, for a reason `Wardrik.Failure` calls
  transient.

  The turn holds the wait: `:interrupt` ends it, and a turn past its deadline
  fails with the call's reason rather than waiting.

  ## A retry that is a value

  A retry is named `{module, value}` where it is data:
  the module implements `again/3`, with the value as its last argument, and
  the value is written to the store with the agent.
  """

  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Retry.Backoff
  alias Wardrik.Scope

  @typedoc "A retry as a scope holds it: a module, or a module and the value it reads."
  @type t() :: module() | {module(), term()}

  @typedoc "Ask again after so many milliseconds, or let the call fail."
  @type decision() :: {:again, non_neg_integer()} | :stop

  @doc """
  Whether to ask `request` again, whose `attempts` hold the try that just
  failed first.
  """
  @callback again(Request.t(), Scope.t()) :: decision()
  @callback again(Request.t(), Scope.t(), value :: term()) :: decision()

  @optional_callbacks again: 2, again: 3

  @doc "What the scope's retry decides for `request`, or the config's backoff without one."
  @spec again(Scope.t(), Request.t()) :: decision()
  def again(%Scope{retry: nil, config: config} = scope, %Request{} = request),
    do: Backoff.again(request, scope, config.retries)

  def again(%Scope{retry: {module, value}} = scope, %Request{} = request),
    do: module.again(request, scope, value)

  def again(%Scope{retry: module} = scope, %Request{} = request), do: module.again(request, scope)
end
