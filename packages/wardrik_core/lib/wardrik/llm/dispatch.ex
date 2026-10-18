defprotocol Wardrik.LLM.Dispatch do
  @moduledoc """
  The seam every model call passes through.

  A turn does not call a provider directly. It builds a `Wardrik.LLM.Request`,
  and `Wardrik.Call.Pipeline` asks the dispatch to admit it, makes the call the
  dispatch hands back, and reports what happened. A host that has to decide
  which model a call lands on, or which key pays for it, does both here, once,
  rather than wrapping the runtime.

  A host names the value once, as the `:dispatch` of its `Wardrik.Host`, and
  every model call of every agent goes through it. The value carries what its
  implementation needs, such as the gateway it routes to, and is never stored
  with an agent:

      Wardrik.Host.new(store: store, dispatch: %MyApp.Gateway{keys: keys})

  `admit/3` is the only place a credential enters a call, and `settle/3` is
  the only place its usage leaves one. A host that enforces that rule gets a
  structural guarantee out of it: a call that skipped the gateway has no key
  and cannot have been made.

      defmodule MyApp.Gateway do
        defstruct [:keys]
      end

      defimpl Wardrik.LLM.Dispatch, for: MyApp.Gateway do
        def admit(gateway, request, run: run) do
          org = Wardrik.Run.agent_id(run).org

          with {:ok, key, model} <- MyApp.Keys.for(gateway.keys, org, request.model_spec) do
            {:ok, request |> Request.put_model(model) |> Request.put_opts(api_key: key)}
          end
        end

        def settle(_gateway, request, outcome: {:ok, response}, run: run),
          do: MyApp.Billing.record(Wardrik.Run.agent_id(run).org, request.model_spec, response.usage)

        def settle(_gateway, _request, _opts), do: :ok
      end

  A host that names none has `Wardrik.LLM.Dispatch.Direct`, which makes each
  request as it stands, so a deployment that reads its key from the
  environment configures nothing.

  ## One dispatch around another

  A dispatch can hold another and hand it each request, so what the host
  adds, such as recording what each call cost, stays its own while another
  decides where the call goes:

      defmodule MyApp.Metered do
        defstruct inner: %Wardrik.LLM.Dispatch.Direct{}
      end

      defimpl Wardrik.LLM.Dispatch, for: MyApp.Metered do
        def admit(metered, request, opts), do: Wardrik.LLM.Dispatch.admit(metered.inner, request, opts)

        def settle(metered, request, opts) do
          :ok = MyApp.Costs.record(request, opts[:outcome], opts[:run])
          Wardrik.LLM.Dispatch.settle(metered.inner, request, opts)
        end
      end

  Changing where calls go is then changing `:inner`, and nothing else.

  ## Hooks first

  Before the dispatch sees a request, the run's `Wardrik.Hook`s are handed it
  as a `Wardrik.Call` to a `Wardrik.Call.Model`; see `Wardrik.Call.Pipeline`. A
  deny fails the turn as `{:policy_denied, reason}` and an ask parks it, and
  in neither case is the dispatch asked. Every hook hears what an admitted
  call used through `Wardrik.Hook.settle/1`, before the dispatch settles it,
  so a budget counts a call whatever its dispatch does with it.

  ## Refusing a call

  An `{:error, reason}` from `admit/3` fails the turn with that reason and
  the provider is never reached, which is what a disabled model should do.
  Classify the reason so callers know whether to retry it; see `Wardrik.Failure`.

  ## Failing to settle

  By the time `settle/3` hears of a call, the provider has answered it. A
  dispatch that cannot book it, a database write that failed say, answers
  `{:error, reason}`: the reason is logged and the turn carries on with the
  answer, since losing what was paid for to a bookkeeping error is worse
  than losing the book entry.

  Both functions run in the turn's own process, so one that raises fails
  that turn, as any other crash in it does, and the agent takes its next
  message. Answer errors rather than raise them.
  """

  alias Wardrik.LLM.Request

  @typedoc """
  How a model call ended: with its response, interrupted with the text that
  had streamed, or failed. A call that failed after the provider began to
  answer it is `{:error, reason, text}`, with the text that had streamed; one
  that failed before is `{:error, reason}`.
  """
  @type outcome() ::
          {:ok, ReqLLM.Response.t()}
          | {:interrupted, String.t()}
          | {:error, term()}
          | {:error, term(), String.t()}

  @doc """
  Decides what a call actually is, immediately before it is made, under the
  `:run` of the turn making it.

  Return the request to make, which may be the one given. Returning an error
  fails the turn without reaching the provider.
  """
  @spec admit(t(), Request.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def admit(dispatch, request, opts)

  @doc """
  Reports how a call went, as its `:outcome`, under the `:run` of the turn
  that made it.

  Called for every admitted request, including ones that failed or were
  interrupted, so a host that books usage never loses a call it admitted.
  An `{:error, reason}` is logged, and the turn carries on.
  """
  @spec settle(t(), Request.t(), keyword()) :: :ok | {:error, term()}
  def settle(dispatch, request, opts)
end
