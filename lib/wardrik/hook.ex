defmodule Wardrik.Hook do
  @moduledoc """
  A check every call an agent makes passes before it happens, the way a plug
  is a step every request passes through.

  A hook is a module implementing this behaviour, the value its `c:init/1`
  made, and a name that says whose a decision was. An agent carries a list of
  them, and each is handed every `Wardrik.Call` it makes, tool calls and model
  calls, before it goes ahead:

      hooks = [
        Wardrik.Hook.new("careful", WardrikPolicy, policy),
        Wardrik.Hook.new("fridays", MyApp.NoFridayDeploys, timezone: "Europe/London")
      ]

      Wardrik.Fleet.spawn("assistant", config: config, hooks: hooks)

  The value travels with the agent: it is written to the store with the rest
  of the agent's seams and read back on whichever node holds it next, so it
  holds no function and no reference.

      defmodule MyApp.NoFridayDeploys do
        @behaviour Wardrik.Hook

        import Wardrik.Call

        @impl true
        def init(opts), do: Map.new(opts)

        @impl true
        def call(%Wardrik.Call{target: %Wardrik.Call.Tool{name: "deploy"}} = call, %{timezone: tz}) do
          if friday?(tz), do: deny(call, "No deploys on a Friday."), else: call
        end

        def call(call, _value), do: call
      end

  ## Deciding together

  `check/1` hands the call to each hook in order. A hook that leaves it as it
  was allows it; `Wardrik.Call.deny/2` refuses it and skips the hooks after;
  `Wardrik.Call.ask/3` asks a person about it and lets the hooks after have
  their say. So the strictest answer decides: a deny over an ask over an
  allow, and a person asked about a call is shown every prompt at once.

  A hook that lets a call go ahead because a rule of its own names it says
  so with `Wardrik.Call.allow/2`, which is what a gated tool's call waits for;
  see `Wardrik.Call`. Leaving the call as it was lets an ungated call go ahead
  and a gated one wait. `after_outside: true` lets a gated call go ahead
  once its run has read content from outside too.

  A hook changes a call only through those functions, `Wardrik.Call.allow/2`
  and `Wardrik.Call.assign/3`. What it hands back is read for what it denied,
  what it asked, what it allowed and what it assigned, and nothing else: it
  cannot change what the call is, or take back what a hook before it said. A
  hook that raises, throws or exits, hands back something other than a call,
  or takes back what another said, refuses the call.

  ## Once a person approves

  An approved call goes ahead without the hooks being asked about it again.
  Each hook that asked hears of it through `c:approved/2`, where
  `Wardrik.Call.memo/1` is what it asked with.

  ## Once a model call is made

  `c:settle/2` is handed each model call once it has been made, in state
  `:done`, with `:result` and `:usage` set. A call that failed before the
  provider began to answer used nothing, and is not settled. A failure there
  is logged.

  ## Revisions

  `revision/1` names a list of hooks by what it holds. A parked turn records
  the revision it parked under, and one resumed under a different revision
  hands the calls a hook was waiting on to the hooks it has now.
  """

  require Logger

  alias Wardrik.Call
  alias Wardrik.Scope

  @enforce_keys [:name, :module]
  defstruct [:name, :module, :value]

  @type t() :: %__MODULE__{name: String.t(), module: module(), value: term()}

  @doc "Prepares what the hook reads from `opts`. The value it returns is stored, so it is data."
  @callback init(opts :: term()) :: value :: term()

  @doc "Hands the hook a call before it goes ahead, and takes back what it says of it."
  @callback call(Call.t(), value :: term()) :: Call.t()

  @doc "Hears that a person approved a call this hook asked about."
  @callback approved(Call.t(), value :: term()) :: any()

  @doc "Hears what a model call used."
  @callback settle(Call.t(), value :: term()) :: any()

  @optional_callbacks approved: 2, settle: 2

  @doc "A hook named `name`, reading what `module`'s `c:init/1` makes of `opts`."
  @spec new(String.t(), module(), term()) :: t()
  def new(name, module, opts \\ []) when is_binary(name) and is_atom(module),
    do: %__MODULE__{name: name, module: module, value: module.init(opts)}

  @doc """
  Hands an unchecked call to every hook on its scope, and sets its state to
  what they said: `:denied`, `:waiting` or `:allowed`. A call no hook is
  asked about is allowed.
  """
  @spec check(Call.t()) :: Call.t()
  def check(%Call{state: :unchecked, scope: %Scope{hooks: hooks}} = call) do
    hooks
    |> Enum.reduce_while(call, fn hook, call ->
      checked = ask(hook, Call.put_hook(call, hook.name))
      if checked.halted, do: {:halt, checked}, else: {:cont, checked}
    end)
    |> Call.checked()
  end

  defp ask(%__MODULE__{module: module, value: value} = hook, call) do
    case module.call(call, value) do
      %Call{} = answered -> kept(call, answered, hook)
      other -> Call.deny(call, "Hook #{hook.name} answered #{inspect(other)}")
    end
  catch
    kind, reason -> Call.deny(call, "Hook #{hook.name} failed: #{Exception.format(kind, reason)}")
  end

  # What a hook said, and only that: asks added after the ones it was handed,
  # a denial of its own, an allowance in its own name, and what it assigned.
  defp kept(call, answered, hook) do
    if own?(call.asks, answered.asks, & &1.by, hook) and
         own?(call.allowed, answered.allowed, & &1, hook) and
         own?(call.allowed_after_outside, answered.allowed_after_outside, & &1, hook) and
         (answered.denied == nil or answered.denied.by == hook.name) do
      %{
        call
        | asks: answered.asks,
          allowed: answered.allowed,
          allowed_after_outside: answered.allowed_after_outside,
          denied: answered.denied,
          halted: answered.denied != nil,
          assigns: answered.assigns
      }
    else
      Call.deny(call, "Hook #{hook.name} changed what another hook said")
    end
  end

  # What was there before is kept as it was, and what was added is the hook's.
  defp own?(before, now, by, hook) do
    {kept, added} = Enum.split(now, length(before))
    kept == before and Enum.all?(added, &(by.(&1) == hook.name))
  end

  @doc """
  Tells each hook that asked about an approved call that a person approved
  it. A hook no longer on the call's scope is not told.
  """
  @spec approved(Call.t()) :: :ok
  def approved(%Call{state: :approved, scope: %Scope{hooks: hooks}} = call) do
    for %Call.Ask{by: name} <- call.asks,
        %__MODULE__{} = hook <- [Enum.find(hooks, &(&1.name == name))] do
      optional(hook, :approved, Call.put_hook(call, name))
    end

    :ok
  end

  @doc "Tells every hook on its scope what a model call used."
  @spec settle(Call.t()) :: :ok
  def settle(%Call{target: %Call.Model{}, state: :done, scope: %Scope{hooks: hooks}} = call) do
    Enum.each(hooks, &optional(&1, :settle, Call.put_hook(call, &1.name)))
  end

  defp optional(%__MODULE__{module: module, value: value} = hook, function, call) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 2),
      do: apply(module, function, [call, value])
  catch
    kind, reason ->
      Logger.error("Hook #{hook.name} failed in #{function}: #{Exception.format(kind, reason)}")
  end

  @doc "A name for `hooks` that changes whenever what they hold does."
  @spec revision([t()]) :: String.t()
  def revision(hooks) when is_list(hooks) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(hooks, [:deterministic]))
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end
end
