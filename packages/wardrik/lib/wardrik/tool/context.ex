defmodule Wardrik.Tool.Context do
  @moduledoc """
  What a tool built with `Wardrik.Tool.new!/1` is handed with a call's
  arguments: the run the call is part of, and what the runtime did for it.

    * `:scope` - the `Wardrik.Scope` the call runs under: whose work it is,
      what it may do, and whether the run has read content from outside
    * `:call_id` - the id the model gave the call
    * `:idempotency_key` - what names this call to the systems it reaches,
      the same when its turn is replayed; see `Wardrik.Ledger.idempotency_key/2`
    * `:credentials` - the credentials the tool's annotations named, resolved
      for this call, by name; see `Wardrik.Tool.Annotations`
    * `:progress` - reports how far the call has got; see `progress/3`

        def run(%{query: query}, %Wardrik.Tool.Context{} = context) do
          github = context.credentials["github"]
          Wardrik.Tool.Context.progress(context, 1, 2)
          ...
        end
  """

  alias Wardrik.Call
  alias Wardrik.Event
  alias Wardrik.Ledger
  alias Wardrik.Scope

  @enforce_keys [:scope, :call_id, :idempotency_key, :progress]
  defstruct [:scope, :call_id, :idempotency_key, :progress, credentials: %{}]

  @type t() :: %__MODULE__{
          scope: Scope.t(),
          call_id: String.t(),
          idempotency_key: String.t(),
          credentials: %{Wardrik.Credential.ref() => Wardrik.Credential.t()},
          progress: (number(), number() | nil -> :ok)
        }

  @doc false
  @spec new(Call.t(), %{Wardrik.Credential.ref() => Wardrik.Credential.t()}) :: t()
  def new(%Call{id: id, scope: %Scope{source: source} = scope} = call, credentials) do
    name = Call.name(call)

    %__MODULE__{
      scope: scope,
      call_id: id,
      idempotency_key: Ledger.idempotency_key(call),
      credentials: credentials,
      progress: fn progress, total ->
        Event.emit(source, {:tool_progress, id, name, progress, total})
      end
    }
  end

  @doc """
  Reports how far the call has got, on the turn's event stream: emits
  `{:tool_progress, call_id, name, progress, total}` under the call's span,
  where `total` is `nil` for work with no known end.

      Wardrik.Tool.Context.progress(context, 3, 10)
  """
  @spec progress(t(), number(), number() | nil) :: :ok
  def progress(%__MODULE__{progress: report}, progress, total \\ nil),
    do: report.(progress, total)
end
