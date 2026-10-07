defmodule Wardrik.LLM.Dispatch do
  @moduledoc """
  The seam every model call passes through.

  A turn does not call a provider directly. It builds a `Wardrik.LLM.Request` and
  asks the dispatch to admit it, makes the call the dispatch hands back, and
  reports what happened. A host that has to decide which model a call lands
  on, or which key pays for it, does both here, once, rather than wrapping the
  runtime.

      Wardrik.Fleet.spawn(id, config: config, dispatch: MyApp.Gateway)

  `c:admit/2` is the only place a credential enters a call, and `c:settle/3`
  is the only place its usage leaves one. A host that enforces that rule gets a
  structural guarantee out of it: a call that skipped the gateway has no key
  and cannot have been made.

      defmodule MyApp.Gateway do
        @behaviour Wardrik.LLM.Dispatch

        @impl true
        def admit(request, scope) do
          org = Wardrik.Scope.agent_id(scope).org

          with {:ok, key, model} <- MyApp.Keys.for(org, request.model_spec) do
            {:ok, request |> Request.put_model(model) |> Request.put_opts(api_key: key)}
          end
        end

        @impl true
        def settle(request, {:ok, response}, scope) do
          MyApp.Billing.record(Wardrik.Scope.agent_id(scope).org, request.model_spec, response.usage)
        end

        def settle(_request, _outcome, _scope), do: :ok
      end

  Without a dispatch the request is made as it stands, so a deployment that
  reads its key from the environment configures nothing.

  ## Hooks first

  Before the dispatch sees a request, the scope's `Wardrik.Hook`s are handed it
  as a `Wardrik.Call` to a `Wardrik.Call.Model`. A deny fails the turn as
  `{:policy_denied, reason}` and an ask parks it, and in neither case is the
  dispatch asked. Every hook hears what an admitted call used through
  `Wardrik.Hook.settle/1`.

  ## Refusing a call

  An `{:error, reason}` from `c:admit/2` fails the turn with that reason and
  the provider is never reached, which is what a disabled model should do.
  Classify the reason so callers know whether to retry it; see `Wardrik.Failure`.

  ## A dispatch that is a value

  A dispatch written as data is named with the module that reads it, as
  `{module, value}`. The module implements each callback with the value as one
  more argument, `admit/3` and `settle/4`, and the value is written to the
  store with the agent.
  """

  alias Wardrik.Call
  alias Wardrik.Hook
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Usage
  alias Wardrik.Scope

  @typedoc "A dispatch as a scope holds it: a module, or a module and the value it reads."
  @type t() :: module() | {module(), term()}

  @typedoc "What `admit/3` answers: the request to make, the call waiting on a person, or why not."
  @type admission() :: {:ok, Request.t()} | {:park, Call.t()} | {:error, term()}

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
  Decides what a call actually is, immediately before it is made.

  Return the request to make, which may be the one given. Returning an error
  fails the turn without reaching the provider.
  """
  @callback admit(Request.t(), Scope.t()) :: {:ok, Request.t()} | {:error, term()}
  @callback admit(Request.t(), Scope.t(), value :: term()) ::
              {:ok, Request.t()} | {:error, term()}

  @doc """
  Reports how a call went, once it has.

  Called for every admitted request, including ones that failed or were
  interrupted, so a host that books usage never loses a call it admitted. Its
  return value is ignored and a failure here does not fail the turn.
  """
  @callback settle(Request.t(), outcome(), Scope.t()) :: any()
  @callback settle(Request.t(), outcome(), Scope.t(), value :: term()) :: any()

  @optional_callbacks admit: 2, admit: 3, settle: 3, settle: 4

  require Logger

  @doc """
  Admits `request` under `scope`: hands its call to the scope's hooks, then
  the request to its dispatch, passing the request through where there is
  none. A call waiting on a person is handed back with no scope, as it is
  written down.

  `decided: true` skips the hooks, for a call a person has already approved.
  """
  @spec admit(Scope.t(), Request.t(), keyword()) :: admission()
  def admit(%Scope{} = scope, %Request{} = request, opts \\ []) do
    if Keyword.get(opts, :decided, false) do
      dispatch(scope, request)
    else
      case request |> Call.model(scope) |> Hook.check() do
        %Call{state: :allowed} -> dispatch(scope, request)
        %Call{state: :denied, denied: denied} -> {:error, {:policy_denied, denied.reason}}
        %Call{state: :waiting} = waiting -> {:park, Call.under(waiting, nil)}
      end
    end
  end

  defp dispatch(%Scope{dispatch: nil}, request), do: {:ok, request}

  defp dispatch(%Scope{dispatch: dispatch} = scope, request) do
    case call(dispatch, :admit, [request, scope]) do
      {:ok, %Request{} = admitted} -> {:ok, admitted}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_admit_result, other}}
    end
  catch
    kind, reason -> {:error, {:dispatch_failed, Exception.format(kind, reason)}}
  end

  @doc """
  Reports `outcome` for `request` to the dispatch and the hooks.

  A dispatch that fails here is logged and ignored: the call already happened,
  and losing the answer to a bookkeeping error would be worse than losing the
  book entry.
  """
  @spec settle(Scope.t(), Request.t(), outcome()) :: :ok
  def settle(%Scope{} = scope, %Request{} = request, outcome) do
    if scope.dispatch, do: optional(scope.dispatch, :settle, [request, outcome, scope])

    case Usage.of(request, outcome) do
      nil -> :ok
      usage -> request |> Call.model(scope) |> Call.used(outcome, usage) |> Hook.settle()
    end
  end

  defp optional(dispatch, function, args) do
    if implements?(dispatch, function, length(args)), do: call(dispatch, function, args)
    :ok
  catch
    kind, reason ->
      Logger.error(
        "Dispatch #{name(dispatch)} failed in #{function}: #{Exception.format(kind, reason)}"
      )

      :ok
  end

  defp call({module, value}, function, args), do: apply(module, function, args ++ [value])
  defp call(module, function, args), do: apply(module, function, args)

  defp implements?({module, _value}, function, arity), do: exports?(module, function, arity + 1)
  defp implements?(module, function, arity), do: exports?(module, function, arity)

  defp exports?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp name({module, _value}), do: inspect(module)
  defp name(module), do: inspect(module)
end
