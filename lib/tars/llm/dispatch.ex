defmodule Tars.LLM.Dispatch do
  @moduledoc """
  The seam every model call passes through.

  A turn does not call a provider directly. It builds a `Tars.LLM.Request` and
  asks the dispatch to admit it, makes the call the dispatch hands back, and
  reports what happened. A host that has to decide what a call may cost, which
  model it lands on, or which key pays for it does all three here, once, rather
  than wrapping the runtime.

      Tars.Agent.Supervisor.start(:assistant, config: config, dispatch: MyApp.Gateway)

  `admit/2` is the only place a credential enters a call, and `settle/3` is the
  only place its usage leaves one. A host that enforces that rule gets a
  structural guarantee out of it: a call that skipped the gateway has no key
  and cannot have been made.

      defmodule MyApp.Gateway do
        @behaviour Tars.LLM.Dispatch

        @impl true
        def admit(request, scope) do
          with {:ok, key, model} <- MyApp.Budget.admit(scope.org, request.model_spec) do
            {:ok, request |> Request.put_model(model) |> Request.put_opts(api_key: key)}
          end
        end

        @impl true
        def settle(request, {:ok, response}, scope) do
          MyApp.Billing.record(scope.org, request.model_spec, response.usage)
        end

        def settle(_request, _outcome, _scope), do: :ok
      end

  Without a dispatch the request is made as it stands, so a deployment that
  reads its key from the environment configures nothing.

  ## Refusing a call

  An `{:error, reason}` from `admit/2` fails the turn with that reason and the
  provider is never reached, which is what a budget ceiling or a disabled model
  should do. Classify the reason so callers know whether to retry it; see
  `Tars.Failure`.
  """

  alias Tars.LLM.Request
  alias Tars.Scope

  @typedoc "How a model call ended."
  @type outcome() ::
          {:ok, ReqLLM.Response.t()} | {:interrupted, String.t()} | {:error, term()}

  @doc """
  Decides what a call actually is, immediately before it is made.

  Return the request to make, which may be the one given. Returning an error
  fails the turn without reaching the provider.
  """
  @callback admit(Request.t(), Scope.t()) :: {:ok, Request.t()} | {:error, term()}

  @doc """
  Reports how a call went, once it has.

  Called for every admitted request, including ones that failed or were
  interrupted, so a host that books usage never loses a call it admitted. Its
  return value is ignored and a failure here does not fail the turn.
  """
  @callback settle(Request.t(), outcome(), Scope.t()) :: any()

  @optional_callbacks settle: 3

  require Logger

  @doc """
  Admits `request` under `scope`, passing it through when there is no dispatch.
  """
  @spec admit(Scope.t(), Request.t()) :: {:ok, Request.t()} | {:error, term()}
  def admit(%Scope{dispatch: nil}, %Request{} = request), do: {:ok, request}

  def admit(%Scope{dispatch: dispatch} = scope, %Request{} = request) do
    case dispatch.admit(request, scope) do
      {:ok, %Request{} = admitted} -> {:ok, admitted}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_admit_result, other}}
    end
  catch
    kind, reason -> {:error, {:dispatch_failed, Exception.format(kind, reason)}}
  end

  @doc """
  Reports `outcome` for `request`, doing nothing when there is no dispatch.

  A dispatch that fails here is logged and ignored: the call already happened,
  and losing the answer to a bookkeeping error would be worse than losing the
  book entry.
  """
  @spec settle(Scope.t(), Request.t(), outcome()) :: :ok
  def settle(%Scope{dispatch: nil}, %Request{}, _outcome), do: :ok

  def settle(%Scope{dispatch: dispatch} = scope, %Request{} = request, outcome) do
    if function_exported?(dispatch, :settle, 3) do
      dispatch.settle(request, outcome, scope)
    end

    :ok
  catch
    kind, reason ->
      Logger.error(
        "Dispatch #{inspect(dispatch)} failed to settle: #{Exception.format(kind, reason)}"
      )

      :ok
  end
end
