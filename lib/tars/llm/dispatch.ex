defmodule Tars.LLM.Dispatch do
  @moduledoc """
  The seam every model call passes through.

  A turn does not call a provider directly. It builds a `Tars.LLM.Request` and
  asks the dispatch to admit it, makes the call the dispatch hands back, and
  reports what happened. A host that has to decide what a call may cost, which
  model it lands on, or which key pays for it does all three here, once, rather
  than wrapping the runtime.

      Tars.Fleet.spawn("assistant", config: config, dispatch: MyApp.Gateway)

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

  ## Refusing a call, or asking first

  An `{:error, reason}` from `admit/2` fails the turn with that reason and the
  provider is never reached, which is what a disabled model should do. Classify
  the reason so callers know whether to retry it; see `Tars.Failure`.

  A `{:park, prompt}` parks the turn before the call instead, the way a policy
  that asks parks a tool call: the agent waits, and `Tars.Agent.parked/1` lists
  a call named `model` with the prompt a person is shown. Approving it calls
  `c:approved/2`, then asks `admit/2` again, so a dispatch that parked because
  a budget ran out raises the budget there and admits the call it could not
  before. Denying it ends the turn as `{:policy_denied, reason}`.

  ## A dispatch that is a value

  A dispatch written as data is named with the module that reads it, as
  `{module, value}`, the way a `Tars.Policy` can be. The module implements
  each callback with the value as one more argument, `admit/3`, `settle/4` and
  `approved/3`, and the value is written to the store with the agent.
  """

  alias Tars.LLM.Request
  alias Tars.Scope

  @typedoc "A dispatch as a scope holds it: a module, or a module and the value it reads."
  @type t() :: module() | {module(), term()}

  @typedoc "What `admit/2` answers."
  @type admission() :: {:ok, Request.t()} | {:park, String.t()} | {:error, term()}

  @typedoc "How a model call ended."
  @type outcome() ::
          {:ok, ReqLLM.Response.t()} | {:interrupted, String.t()} | {:error, term()}

  @doc """
  Decides what a call actually is, immediately before it is made.

  Return the request to make, which may be the one given. Returning an error
  fails the turn without reaching the provider, and `{:park, prompt}` parks it
  until a person decides.
  """
  @callback admit(Request.t(), Scope.t()) :: admission()
  @callback admit(Request.t(), Scope.t(), value :: term()) :: admission()

  @doc """
  Reports how a call went, once it has.

  Called for every admitted request, including ones that failed or were
  interrupted, so a host that books usage never loses a call it admitted. Its
  return value is ignored and a failure here does not fail the turn.
  """
  @callback settle(Request.t(), outcome(), Scope.t()) :: any()
  @callback settle(Request.t(), outcome(), Scope.t(), value :: term()) :: any()

  @doc """
  Hears that a person approved a call this dispatch parked, before `admit/2`
  is asked about it again. Its return value is ignored.
  """
  @callback approved(Request.t(), Scope.t()) :: any()
  @callback approved(Request.t(), Scope.t(), value :: term()) :: any()

  @optional_callbacks admit: 2, admit: 3, settle: 3, settle: 4, approved: 2, approved: 3

  require Logger

  @doc """
  Admits `request` under `scope`, passing it through when there is no dispatch.
  """
  @spec admit(Scope.t(), Request.t()) :: admission()
  def admit(%Scope{dispatch: nil}, %Request{} = request), do: {:ok, request}

  def admit(%Scope{dispatch: dispatch} = scope, %Request{} = request) do
    case call(dispatch, :admit, [request, scope]) do
      {:ok, %Request{} = admitted} -> {:ok, admitted}
      {:park, prompt} when is_binary(prompt) -> {:park, prompt}
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
    optional(dispatch, :settle, [request, outcome, scope])
  end

  @doc """
  Tells the dispatch a person approved a call it parked. A dispatch that fails
  here is logged and ignored, and `admit/2` decides the call as it stands.
  """
  @spec approved(Scope.t(), Request.t()) :: :ok
  def approved(%Scope{dispatch: nil}, %Request{}), do: :ok

  def approved(%Scope{dispatch: dispatch} = scope, %Request{} = request) do
    optional(dispatch, :approved, [request, scope])
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
