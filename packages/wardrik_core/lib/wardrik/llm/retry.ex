defprotocol Wardrik.LLM.Retry do
  @moduledoc """
  The seam that decides whether a model call that failed is asked again, and
  after how long, and what happens once it is not.

  A turn whose model call fails hands the request, with the failed try added
  to its `attempts` (see `Wardrik.LLM.Attempt`), to the run's retry. Asked
  again, the request goes through the hooks and the `Wardrik.LLM.Dispatch`
  as the first try did, under a message id of its own, so what the failed
  try had streamed is never taken for the answer.

  A retry is a value the run holds, written to the store with the agent.
  `Wardrik.LLM.Retry.Backoff` is a run's retry unless it names another.

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

  The turn holds the wait, and publishes a `Wardrik.Event.ModelRetrying`
  before it: `:interrupt` ends the wait, and a turn past its deadline fails
  with the call's reason rather than waiting.

  A retry that asks again no more says what happens instead: `:ask` parks the
  turn on its model call, for a person to say whether to try again, and
  `:fail` fails the turn with the call's reason. See `Wardrik.LLM.Turn`.
  """

  alias Wardrik.LLM.Request

  @typedoc """
  Ask again after `wait` milliseconds, as one of `attempts` tries after the
  first; or ask a person whether to try again; or let the call fail.
  """
  @type decision() ::
          {:again, wait :: non_neg_integer(), attempts :: non_neg_integer()} | :ask | :fail

  @doc """
  What to do about `request`, whose `attempts` hold the try that just failed
  first. `opts` hold the `:run` the call was made under.
  """
  @spec again(t(), Request.t(), keyword()) :: decision()
  def again(retry, request, opts)
end
