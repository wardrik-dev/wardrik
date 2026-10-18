defmodule Wardrik.Tool.Context do
  @moduledoc """
  What a `Wardrik.Tool` is handed with a call's arguments: the run the call
  is part of, and what the runtime did for it.

    * `:run` - the `Wardrik.Run` the call runs under: whose work it is,
      what it may do, and whether the run has read content from outside
    * `:sender` - the `Wardrik.Principal` who asked for the turn the call is
      part of, or `nil` where nobody did, as a trigger's; see `Wardrik.Run`.
      A tool that acts for that person asks `Wardrik.Grants` what they may do
    * `:call_id` - the id the model gave the call
    * `:idempotency_key` - what names this call to the systems it reaches,
      the same when its turn is replayed; see `Wardrik.Ledger.Key.idempotency/2`
    * `:credentials` - the credentials the tool's annotations named, resolved
      for this call, by name; see `Wardrik.Tool.Annotations`
    * `:in_doubt` - whether the call runs again because it may already have
      done what it does, under the same idempotency key; see
      `Wardrik.Call.Pipeline`
    * `:progress` - reports how far the call has got; see `progress/3`

        def run(%{query: query}, %Wardrik.Tool.Context{} = context) do
          github = context.credentials["github"]
          Wardrik.Tool.Context.progress(context, 1, 2)
          ...
        end
  """

  alias Wardrik.Call
  alias Wardrik.Event
  alias Wardrik.Run

  @enforce_keys [:run, :call_id, :idempotency_key, :progress]
  defstruct [
    :run,
    :sender,
    :call_id,
    :idempotency_key,
    :progress,
    credentials: %{},
    in_doubt: false
  ]

  @type t() :: %__MODULE__{
          run: Run.t(),
          sender: Wardrik.Principal.t() | nil,
          call_id: String.t(),
          idempotency_key: String.t(),
          credentials: %{Wardrik.Credential.ref() => Wardrik.Credential.t()},
          in_doubt: boolean(),
          progress: (number(), number() | nil -> :ok)
        }

  @doc false
  @spec new(Call.t(), %{Wardrik.Credential.ref() => Wardrik.Credential.t()}, keyword()) :: t()
  def new(%Call{id: id, run: %Run{source: source} = run} = call, credentials, opts \\ []) do
    name = Call.name(call)

    %__MODULE__{
      run: run,
      sender: run.sender,
      call_id: id,
      idempotency_key: Wardrik.Ledger.Key.idempotency(call),
      credentials: credentials,
      in_doubt: Keyword.get(opts, :in_doubt, false),
      progress: fn progress, total ->
        Event.emit(source, %Event.ToolProgress{
          call_id: id,
          name: name,
          progress: progress,
          total: total
        })
      end
    }
  end

  @doc """
  Reports how far the call has got, on the turn's event stream: emits
  `Wardrik.Event.ToolProgress` under the call's span,
  where `total` is `nil` for work with no known end.

      Wardrik.Tool.Context.progress(context, 3, 10)
  """
  @spec progress(t(), number(), number() | nil) :: :ok
  def progress(%__MODULE__{progress: report}, progress, total \\ nil),
    do: report.(progress, total)
end
