defmodule Wardrik.Call do
  @moduledoc """
  One call an agent means to make, to a tool or to a model, from the moment
  it is proposed until it has been answered.

  A call is a token, the way a `Plug.Conn` is. `Wardrik.Hook`s are handed it and
  hand it back, and change it only through `deny/2`, `ask/3`, `allow/1` and
  `assign/3`.
  The runtime moves it through its states, and it is the same value whether
  it is being decided, waiting on a person, or answered.

  A tool built with `Wardrik.Tool.new!/1` is handed the call too, and answers it
  with `answer/2` or parks it with `park/2`, and marks with `taint/1` a call
  whose answer holds content from outside.

  What the call goes to is its `:target`, a `Wardrik.Call.Tool` or a
  `Wardrik.Call.Model`, and a hook matches on it:

      def call(%Wardrik.Call{target: %Wardrik.Call.Tool{name: "deploy"}} = call, _value) do
        if friday?(), do: Wardrik.Call.deny(call, "No deploys on a Friday."), else: call
      end

      def call(call, _value), do: call

  ## Fields

  What is being attempted, which hooks read and never change:

    * `:id` - the provider's id for a tool call; `model_` and a random suffix
      for a model call
    * `:target` - the `Wardrik.Call.Tool` or `Wardrik.Call.Model` it goes to
    * `:scope` - the `Wardrik.Scope` it runs under, `nil` while it waits

  What was said about it, written through the functions here:

    * `:denied` - the `Wardrik.Call.Denial` that refused it
    * `:asks` - the `Wardrik.Call.Ask`s it waits on, in the order they were asked
    * `:allowed` - the names of the hooks that allowed it by name
    * `:halted` - whether the hooks after the one that refused it are skipped
    * `:assigns` - what hooks tell the hooks after them

  What became of it, set by the runtime:

    * `:state` - see below
    * `:result` - what a tool answered, `{:ok, output}` or `{:error, reason}`,
      or how a model call ended, as `t:Wardrik.LLM.Dispatch.outcome/0`
    * `:tainted` - whether what it answered holds content from outside; see
      `taint/1`

  `:private` is for Wardrik and the libraries built on it.

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

  ## Gated tools

  A call to a gated tool (see `c:Wardrik.Tool.gated?/1`) goes ahead only where
  a hook allowed it by name, with `allow/1`, and waits on its tool otherwise.
  While the run it belongs to has read content from outside (see
  `Wardrik.Scope`'s `:tainted`), it waits on its tool even so, unless the
  run's config trusts outside content: what the run read may be what asked
  for it. A deny still refuses it and an ask still asks. A call to a tool that is not gated goes ahead as the hooks said,
  allowed by name or not.
  """

  alias Wardrik.Call.Ask
  alias Wardrik.Call.Denial
  alias Wardrik.Call.Model
  alias Wardrik.Call.Tool
  alias Wardrik.LLM.Request
  alias Wardrik.Scope

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
    allowed: [],
    tainted: false,
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
          allowed: [String.t()],
          tainted: boolean(),
          result: term(),
          assigns: map(),
          private: map()
        }

  @hook :wardrik_hook

  # -- building ----------------------------------------------------------------

  @doc "The call a model asked for, as `ReqLLM.Response.classify/1` gives it."
  @spec tool(Wardrik.Tool.call(), Scope.t() | nil) :: t()
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
  comes back to this hook's `c:Wardrik.Hook.approved/2` through `memo/1`.
  """
  @spec ask(t(), String.t(), term()) :: t()
  def ask(%__MODULE__{} = call, prompt, memo \\ nil) when is_binary(prompt),
    do: %{call | asks: call.asks ++ [%Ask{by: hook(call), prompt: prompt, memo: memo}]}

  @doc """
  Allows the call by name: says that a rule of this hook names it, where a
  hook that lets it go ahead only by not objecting leaves it as it was. A
  gated tool's call goes ahead only where a hook has said this.
  """
  @spec allow(t()) :: t()
  def allow(%__MODULE__{} = call), do: %{call | allowed: Enum.uniq(call.allowed ++ [hook(call)])}

  @doc "Tells the hooks after this one `value` under `key`."
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{} = call, key, value) when is_atom(key),
    do: %{call | assigns: Map.put(call.assigns, key, value)}

  @doc "Keeps `value` under `key` for Wardrik or a library built on it."
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

  @doc """
  Sets the state the hooks' answers come to: denied, waiting, or allowed. A
  gated tool's call no hook allowed by name, or one in a run that has read
  content from outside, waits on its tool.
  """
  @spec checked(t()) :: t()
  def checked(%__MODULE__{} = call) do
    call = put_hook(call, nil)

    cond do
      call.denied -> %{call | state: :denied}
      call.asks != [] -> %{call | state: :waiting}
      prompt = gate(call) -> wait(call, :tool, prompt)
      true -> %{call | state: :allowed}
    end
  end

  defp gate(%__MODULE__{target: %Tool{gated: true}, allowed: []} = call),
    do: "#{name(call)} is gated, so it asks unless a rule allows it by name, and none does."

  defp gate(
         %__MODULE__{
           target: %Tool{gated: true},
           scope: %Scope{tainted: true, config: %{trust_outside_content: false}}
         } = call
       ) do
    IO.iodata_to_binary([
      Enum.intersperse(call.allowed, ", "),
      " allows #{name(call)}, but this run has read content from outside, ",
      "which may be what asked for it."
    ])
  end

  defp gate(_call), do: nil

  @doc """
  Marks the call's answer as holding content from outside: a page, a message,
  an issue anyone could have written. The run it belongs to is tainted from
  then on, and a gated tool's call later in the run waits on a person however
  its hooks allowed it. A tool built with `Wardrik.Tool.new!/1` marks its own
  call; one that declares `c:Wardrik.Tool.outside_content?/1` has it marked.
  """
  @spec taint(t()) :: t()
  def taint(%__MODULE__{} = call), do: %{call | tainted: true}

  @doc """
  Parks a call a tool was handed: it waits on a person, who is shown `prompt`,
  and the tool is handed it again once they approve.

  `link:` is where the person authorizes, `%{url: url, code: code}`. It is
  kept apart from the prompt: `prompt/1` never holds it, and it is shown only
  where the person answering is, never in an event log or a notice.
  """
  @spec park(t(), String.t(), link: Ask.link()) :: t()
  def park(%__MODULE__{} = call, prompt, opts \\ []) when is_binary(prompt) do
    case Keyword.get(opts, :link) do
      nil ->
        wait(call, :tool, prompt)

      %{url: url} = link when is_binary(url) ->
        %{
          wait(call, :tool, prompt)
          | asks: [%Ask{by: :tool, prompt: prompt, link: Map.put_new(link, :code, nil)}]
        }
    end
  end

  @doc "Where the person a waiting call asks authorizes, where its tool said."
  @spec link(t()) :: Ask.link() | nil
  def link(%__MODULE__{asks: asks}), do: Enum.find_value(asks, & &1.link)

  @doc """
  The call waiting on `by`, `:tool` or `:ledger`, which asks `prompt`. What
  was asked of it before, and approved, is behind it.
  """
  @spec wait(t(), :tool | :ledger, String.t()) :: t()
  def wait(%__MODULE__{} = call, by, prompt) when by in [:tool, :ledger] and is_binary(prompt),
    do: %{call | state: :waiting, asks: [%Ask{by: by, prompt: prompt}]}

  @doc """
  The call refused, with `reason`, by `by`: `:person` unless given, or
  `:ledger` for a call the ledger could not record.
  """
  @spec refuse(t(), :person | :ledger, String.t()) :: t()
  def refuse(%__MODULE__{} = call, by \\ :person, reason)
      when by in [:person, :ledger] and is_binary(reason),
      do: %{call | state: :denied, denied: %Denial{by: by, reason: reason}}

  @doc "The call a person approved."
  @spec approve(t()) :: t()
  def approve(%__MODULE__{state: :waiting} = call), do: %{call | state: :approved}

  @doc "The call as it was proposed, to be asked about again."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = call),
    do: %{
      call
      | state: :unchecked,
        denied: nil,
        asks: [],
        allowed: [],
        halted: false,
        assigns: %{}
    }

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
  The call as `t:Wardrik.Tool.call/0` writes one. A model call is named `model`,
  with the model it goes to as its one argument.
  """
  @spec to_map(t()) :: Wardrik.Tool.call()
  def to_map(%__MODULE__{id: id} = call),
    do: %{id: id, name: name(call), arguments: arguments(call)}

  defp arguments(%__MODULE__{target: %Tool{arguments: arguments}}), do: arguments
  defp arguments(%__MODULE__{target: %Model{} = model}), do: %{"model" => Model.name(model)}
end
