defmodule Wardrik.Hook do
  @moduledoc """
  A check every call an agent makes passes before it happens, the way a plug
  is a step every request passes through.

  A hook is a module implementing this behaviour, the value its `c:init/1`
  made, and a name that says whose a decision was. An agent carries a list of
  them, and each is handed every `Wardrik.Call` it makes, tool calls and model
  calls, before it goes ahead, and says what it makes of it:

      hooks = [
        Wardrik.Hook.new("careful", WardrikPolicy, policy),
        Wardrik.Hook.new("fridays", MyApp.NoFridayDeploys, timezone: "Europe/London")
      ]

      Wardrik.Fleet.spawn(Wardrik.AgentID.new!("assistant", org: "acme"), config: config, hooks: hooks)

  The value travels with the agent: it is written to the store with the rest
  of the agent's seams and read back on whichever node holds it next, so it
  holds no function and no reference.

      defmodule MyApp.NoFridayDeploys do
        use Wardrik.Hook

        @impl true
        def init(opts), do: Map.new(opts)

        @impl true
        def call(%Wardrik.Call{target: %Wardrik.Call.Tool{name: "deploy"}}, %{timezone: tz}) do
          if friday?(tz), do: {:deny, "No deploys on a Friday."}, else: :pass
        end

        def call(_call, _value), do: :pass
      end

  `use Wardrik.Hook` gives a hook a `c:approved/3` and a `c:settle/2` that
  hear nothing, so it defines them only where it has something to hear.

  ## Deciding together

  `check/1` hands the call to each hook in order and writes what each says on
  it; see `t:decision/0`. `:pass` says nothing of the call; `{:deny, reason}`
  refuses it and the hooks after are not asked; `{:ask, prompt}` asks a
  person about it and lets the hooks after have their say. So the strictest
  answer decides: a deny over an ask over a pass, and a person asked about a
  call is shown every prompt at once.

  A hook says `:allow` where a rule of its own names the call and lets it go
  ahead, which is what a gated tool's call waits for; see `Wardrik.Call`.
  `:pass` lets an ungated call go ahead and a gated one wait. What the run
  has read is on the call's run, as `Wardrik.Label`s, for a hook to weigh.

  A hook reads the call and answers; it changes nothing. One that raises,
  throws or exits, or answers with anything else, refuses the call: a check
  that fails does not fail open.

  ## Once a person approves

  An approved call goes ahead without the hooks being asked about it again.
  Each hook that asked hears of it through `c:approved/3`, with the memo it
  asked with.

  ## Once a call is made

  `c:settle/2` is handed each call once it has been made, in state `:done`
  with `:result` set: a tool call its tool answered, and a model call with
  `:usage` set on its target. A model call that failed before the provider
  began to answer used nothing, and is not settled; nor is a call refused, a
  call answered from the ledger, or one waiting on a person. A hook that
  raises there fails the call, as a tool that raises does. A hook that cares
  for one kind of call matches on its target:

      def settle(%Wardrik.Call{target: %Wardrik.Call.Model{usage: usage}}, value), do: book(usage, value)
      def settle(_call, _value), do: :ok

  ## Revisions

  `revision/1` names a list of hooks by what it holds. A parked turn records
  the revision it parked under, and one resumed under a different revision
  hands the calls a hook was waiting on to the hooks it has now.
  """

  alias Wardrik.Call
  alias Wardrik.Run

  @enforce_keys [:name, :module]
  defstruct [:name, :module, :value]

  @type t() :: %__MODULE__{name: String.t(), module: module(), value: term()}

  @typedoc """
  What a hook says of a call.

    * `:pass` - it has no rule for the call
    * `:allow` - a rule of its own names the call and lets it go ahead
    * `{:ask, prompt}` - a person is asked, and shown `prompt`
    * `{:ask, prompt, memo}` - the same, with `memo` handed back to the hook
      through `c:approved/3` once they approve
    * `{:deny, reason}` - the call is refused, for `reason`
  """
  @type decision() ::
          :pass
          | :allow
          | {:ask, String.t()}
          | {:ask, String.t(), memo :: term()}
          | {:deny, String.t()}

  @doc "Prepares what the hook reads from `opts`. The value it returns is stored, so it is data."
  @callback init(opts :: term()) :: value :: term()

  @doc "Says what the hook makes of a call before it goes ahead."
  @callback call(Call.t(), value :: term()) :: decision()

  @doc "Hears that a person approved a call this hook asked about, with the memo it asked with."
  @callback approved(Call.t(), memo :: term(), value :: term()) :: any()

  @doc "Hears what a call did once it was made: what a tool answered, or what a model call used."
  @callback settle(Call.t(), value :: term()) :: any()

  defmacro __using__(_opts) do
    quote do
      @behaviour Wardrik.Hook

      @doc false
      def approved(_call, _memo, _value), do: :ok

      @doc false
      def settle(_call, _value), do: :ok

      defoverridable approved: 3, settle: 2
    end
  end

  @doc "A hook named `name`, reading what `module`'s `c:init/1` makes of `opts`."
  @spec new(String.t(), module(), term()) :: t()
  def new(name, module, opts \\ []) when is_binary(name) and is_atom(module),
    do: %__MODULE__{name: name, module: module, value: module.init(opts)}

  @doc """
  Hands an unchecked call to every hook on its run, writes what each says
  on it, and sets its state to what they came to: `:denied`, `:waiting` or
  `:allowed`. A call no hook is asked about is allowed.
  """
  @spec check(Call.t()) :: Call.t()
  def check(%Call{state: :unchecked, run: %Run{hooks: hooks}} = call) do
    hooks
    |> Enum.reduce_while(call, fn hook, call ->
      case decision(hook, call) do
        {:deny, _reason} = denial -> {:halt, Call.decided(call, hook.name, denial)}
        decision -> {:cont, Call.decided(call, hook.name, decision)}
      end
    end)
    |> Call.checked()
  end

  # What a hook says of the call, in the shapes `t:decision/0` names; an ask
  # without a memo is one with none.
  defp decision(%__MODULE__{module: module, value: value} = hook, call) do
    case module.call(call, value) do
      :pass ->
        :pass

      :allow ->
        :allow

      {:ask, prompt} when is_binary(prompt) ->
        {:ask, prompt, nil}

      {:ask, prompt, memo} when is_binary(prompt) ->
        {:ask, prompt, memo}

      {:deny, reason} when is_binary(reason) ->
        {:deny, reason}

      other ->
        {:deny, "Hook #{hook.name} answered #{inspect(other)}"}
    end
  catch
    kind, reason -> {:deny, "Hook #{hook.name} failed: #{Exception.format(kind, reason)}"}
  end

  @doc """
  Tells each hook that asked about an approved call that a person approved
  it, with the memo it asked with. A hook no longer on the call's run is
  not told.
  """
  @spec approved(Call.t()) :: :ok
  def approved(%Call{state: :approved, run: %Run{hooks: hooks}} = call) do
    for %Call.Ask{by: name, memo: memo} <- call.asks,
        %__MODULE__{module: module, value: value} <- [Enum.find(hooks, &(&1.name == name))] do
      module.approved(call, memo, value)
    end

    :ok
  end

  @doc "Tells every hook on its run what a call did once it was made."
  @spec settle(Call.t()) :: :ok
  def settle(%Call{state: :done, run: %Run{hooks: hooks}} = call) do
    Enum.each(hooks, fn %__MODULE__{module: module, value: value} ->
      module.settle(call, value)
    end)
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
