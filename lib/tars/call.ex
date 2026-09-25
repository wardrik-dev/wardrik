defmodule Tars.Call do
  @moduledoc """
  One call an agent means to make, to a tool or to a model, from the moment
  it is proposed until it has been answered.

  A call is a token, the way a `Plug.Conn` is. `Tars.Hook`s are handed it and
  hand it back, and change it only through `deny/2`, `ask/3` and `assign/3`.
  The runtime moves it through its states, and it is the same value whether
  it is being decided, waiting on a person, or answered.

  What the call goes to is its `:target`, a `Tars.Call.Tool` or a
  `Tars.Call.Model`, and a hook matches on it:

      def call(%Tars.Call{target: %Tars.Call.Tool{name: "deploy"}} = call, _value) do
        if friday?(), do: Tars.Call.deny(call, "No deploys on a Friday."), else: call
      end

      def call(call, _value), do: call

  ## Fields

  What is being attempted, which hooks read and never change:

    * `:id` - the provider's id for a tool call; `model_` and a random suffix
      for a model call
    * `:target` - the `Tars.Call.Tool` or `Tars.Call.Model` it goes to
    * `:scope` - the `Tars.Scope` it runs under, `nil` while it waits

  What was said about it, written through the functions here:

    * `:denied` - the `Tars.Call.Denial` that refused it
    * `:asks` - the `Tars.Call.Ask`s it waits on, in the order they were asked
    * `:halted` - whether the hooks after the one that refused it are skipped
    * `:assigns` - what hooks tell the hooks after them

  What became of it, set by the runtime:

    * `:state` - see below
    * `:result` - what a tool answered, `{:ok, output}` or `{:error, reason}`,
      or how a model call ended, as `t:Tars.LLM.Dispatch.outcome/0`

  `:private` is for Tars and the libraries built on it.

  ## States

  | State | What it means |
  | --- | --- |
  | `:unchecked` | proposed, and not yet asked about |
  | `:allowed` | the hooks let it go ahead |
  | `:denied` | a hook or a person refused it |
  | `:waiting` | something asked, and it waits on a person |
  | `:approved` | a person let it go ahead |
  | `:done` | answered |

  A call waits on a hook, named by the hook's name, on its own tool, `:tool`,
  or on `:ledger`, when it began before its agent was lost and may already
  have done what it does.
  """

  alias Tars.Call.Ask
  alias Tars.Call.Denial
  alias Tars.Call.Model
  alias Tars.Call.Tool
  alias Tars.LLM.Request
  alias Tars.Scope

  @enforce_keys [:id, :target]
  defstruct [
    :id,
    :target,
    :scope,
    :denied,
    :result,
    state: :unchecked,
    halted: false,
    asks: [],
    assigns: %{},
    private: %{}
  ]

  @type state() :: :unchecked | :allowed | :denied | :waiting | :approved | :done

  @type t() :: %__MODULE__{
          id: String.t(),
          target: Tool.t() | Model.t(),
          scope: Scope.t() | nil,
          state: state(),
          halted: boolean(),
          denied: Denial.t() | nil,
          asks: [Ask.t()],
          result: term(),
          assigns: map(),
          private: map()
        }

  @hook :tars_hook

  # -- building ----------------------------------------------------------------

  @doc "The call a model asked for, as `ReqLLM.Response.classify/1` gives it."
  @spec tool(Tars.Tool.call(), Scope.t() | nil) :: t()
  def tool(%{id: id, name: name, arguments: arguments}, scope \\ nil),
    do: %__MODULE__{id: id, target: %Tool{name: name, arguments: arguments}, scope: scope}

  @doc "The model call `request` makes."
  @spec model(Request.t(), Scope.t() | nil) :: t()
  def model(%Request{} = request, scope \\ nil) do
    %__MODULE__{
      id: "model_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
      target: Model.new(request),
      scope: scope
    }
  end

  # -- for hooks ---------------------------------------------------------------

  @doc "Refuses the call with `reason`, and skips the hooks after this one."
  @spec deny(t(), String.t()) :: t()
  def deny(%__MODULE__{} = call, reason) when is_binary(reason),
    do: %{call | denied: %Denial{by: hook(call), reason: reason}, halted: true}

  @doc """
  Asks a person about the call before it goes ahead, with `prompt`. The memo
  comes back to this hook's `c:Tars.Hook.approved/2` through `memo/1`.
  """
  @spec ask(t(), String.t(), term()) :: t()
  def ask(%__MODULE__{} = call, prompt, memo \\ nil) when is_binary(prompt),
    do: %{call | asks: call.asks ++ [%Ask{by: hook(call), prompt: prompt, memo: memo}]}

  @doc "Tells the hooks after this one `value` under `key`."
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{} = call, key, value) when is_atom(key),
    do: %{call | assigns: Map.put(call.assigns, key, value)}

  @doc "Keeps `value` under `key` for Tars or a library built on it."
  @spec put_private(t(), atom(), term()) :: t()
  def put_private(%__MODULE__{} = call, key, value) when is_atom(key),
    do: %{call | private: Map.put(call.private, key, value)}

  @doc "The memo the hook being asked left when it asked about the call."
  @spec memo(t()) :: term()
  def memo(%__MODULE__{} = call) do
    by = hook(call)

    case Enum.find(call.asks, &(&1.by == by)) do
      %Ask{memo: memo} -> memo
      nil -> nil
    end
  end

  defp hook(call), do: Map.get(call.private, @hook)

  # -- for the runtime ---------------------------------------------------------

  @doc "The call as the hook named `name` is handed it, or as no hook is, for `nil`."
  @spec put_hook(t(), String.t() | nil) :: t()
  def put_hook(%__MODULE__{} = call, name), do: put_private(call, @hook, name)

  @doc "Sets the state the hooks' answers come to: denied, waiting, or allowed."
  @spec checked(t()) :: t()
  def checked(%__MODULE__{} = call) do
    state =
      cond do
        call.denied -> :denied
        call.asks != [] -> :waiting
        true -> :allowed
      end

    %{put_hook(call, nil) | state: state}
  end

  @doc """
  The call waiting on `by`, `:tool` or `:ledger`, which asks `prompt`. What
  was asked of it before, and approved, is behind it.
  """
  @spec wait(t(), :tool | :ledger, String.t()) :: t()
  def wait(%__MODULE__{} = call, by, prompt) when by in [:tool, :ledger] and is_binary(prompt),
    do: %{call | state: :waiting, asks: [%Ask{by: by, prompt: prompt}]}

  @doc "The call a person refused, with `reason`."
  @spec refuse(t(), String.t()) :: t()
  def refuse(%__MODULE__{} = call, reason) when is_binary(reason),
    do: %{call | state: :denied, denied: %Denial{by: :person, reason: reason}}

  @doc "The call a person approved."
  @spec approve(t()) :: t()
  def approve(%__MODULE__{state: :waiting} = call), do: %{call | state: :approved}

  @doc "The call as it was proposed, to be asked about again."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = call),
    do: %{call | state: :unchecked, denied: nil, asks: [], halted: false, assigns: %{}}

  @doc "A tool call answered with `result`, `{:ok, output}` or `{:error, reason}`."
  @spec answer(t(), {:ok, term()} | {:error, term()}) :: t()
  def answer(%__MODULE__{target: %Tool{}} = call, result),
    do: %{call | state: :done, result: result}

  @doc "A model call that ended as `outcome`, having used `usage`."
  @spec used(t(), term(), map()) :: t()
  def used(%__MODULE__{target: %Model{} = model} = call, outcome, usage),
    do: %{call | state: :done, result: outcome, target: %{model | usage: usage}}

  @doc "The call under `scope`, or under none for one that is written down."
  @spec under(t(), Scope.t() | nil) :: t()
  def under(%__MODULE__{} = call, scope), do: %{call | scope: scope}

  # -- reading -----------------------------------------------------------------

  @doc "What the call is named as a person reads it: the tool's name, or `model`."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{target: %Tool{name: name}}), do: name
  def name(%__MODULE__{target: %Model{}}), do: "model"

  @doc "Whether the call waits on a person."
  @spec waiting?(t()) :: boolean()
  def waiting?(%__MODULE__{state: state}), do: state == :waiting

  @doc "Whether anything named `by` asked about the call."
  @spec asked_by?(t(), String.t() | atom()) :: boolean()
  def asked_by?(%__MODULE__{asks: asks}, by), do: Enum.any?(asks, &(&1.by == by))

  @doc "Whether a hook, rather than its tool or the ledger, asked about the call."
  @spec asked_by_hook?(t()) :: boolean()
  def asked_by_hook?(%__MODULE__{asks: asks}), do: Enum.any?(asks, &is_binary(&1.by))

  @doc "What a person is shown: every prompt asked, in order."
  @spec prompt(t()) :: String.t()
  def prompt(%__MODULE__{asks: asks}), do: Enum.map_join(asks, "\n\n", & &1.prompt)

  @doc """
  The call as `t:Tars.Tool.call/0` writes one. A model call is named `model`,
  with the model it goes to as its one argument.
  """
  @spec to_map(t()) :: Tars.Tool.call()
  def to_map(%__MODULE__{id: id} = call),
    do: %{id: id, name: name(call), arguments: arguments(call)}

  defp arguments(%__MODULE__{target: %Tool{arguments: arguments}}), do: arguments
  defp arguments(%__MODULE__{target: %Model{} = model}), do: %{"model" => Model.name(model)}
end
