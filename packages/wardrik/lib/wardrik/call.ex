defmodule Wardrik.Call do
  @moduledoc """
  One call an agent means to make, to a tool or to a model, from the moment
  it is proposed until it has been answered.

  A call is a token, the way a `Plug.Conn` is. `Wardrik.Hook`s are handed it and
  say what they make of it, and the runtime writes what they said on it with
  `decided/3`. The runtime moves it through its states, and it is the same
  value whether it is being decided, waiting on a person, or answered.

  A tool built with `Wardrik.Tool.new!/1` is handed the call too, and answers it
  with `answer/2` or parks it with `park/2`, and marks with `taint/1` a call
  whose answer holds content from outside.

  What the call goes to is its `:target`, a `Wardrik.Call.Tool` or a
  `Wardrik.Call.Model`, and a hook matches on it:

      def call(%Wardrik.Call{target: %Wardrik.Call.Tool{name: "deploy"}}, _value) do
        if friday?(), do: {:deny, "No deploys on a Friday."}, else: :pass
      end

      def call(_call, _value), do: :pass

  ## Fields

  What is being attempted, which hooks read and never change:

    * `:id` - the provider's id for a tool call; `model_` and a random suffix
      for a model call
    * `:target` - the `Wardrik.Call.Tool` or `Wardrik.Call.Model` it goes to
    * `:scope` - the `Wardrik.Scope` it runs under, `nil` while it waits

  What was said about it, written with `decided/3`:

    * `:denied` - the `Wardrik.Call.Denial` that refused it
    * `:asks` - the `Wardrik.Call.Ask`s it waits on, in the order they were asked
    * `:allowed` - the names of the hooks that allowed it by name
    * `:allowed_after_outside` - those of them that allowed it after content
      from outside too

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
  a hook allowed it by name, with `:allow`, and waits on its tool otherwise.
  While the run it belongs to has read content from outside (see
  `Wardrik.Scope`'s `:tainted`), it waits on its tool even so, since what the
  run read may be what asked for it, unless a hook allowed it with
  `{:allow, after_outside: true}`. A deny still refuses it and an ask still asks. A call
  to a tool that is not gated goes ahead as the hooks said, allowed by name or
  not.
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
    asks: [],
    allowed: [],
    allowed_after_outside: [],
    tainted: false,
    private: %{}
  ]

  @type state() :: :unchecked | :allowed | :denied | :waiting | :approved | :done

  @type t() :: %__MODULE__{
          id: String.t(),
          target: Tool.t() | Model.t(),
          scope: Scope.t() | nil,
          state: state(),
          denied: Denial.t() | nil,
          asks: [Ask.t()],
          allowed: [String.t()],
          allowed_after_outside: [String.t()],
          tainted: boolean(),
          result: term(),
          private: map()
        }

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

  # -- what the hooks said -----------------------------------------------------

  @doc """
  The call with what the hook named `by` said of it written on it; see
  `t:Wardrik.Hook.decision/0`. An ask is kept after those before it, and an
  allow in the hook's own name.
  """
  @spec decided(t(), String.t(), Wardrik.Hook.decision()) :: t()
  def decided(%__MODULE__{} = call, _by, :pass), do: call

  def decided(%__MODULE__{} = call, by, :allow),
    do: %{call | allowed: Enum.uniq(call.allowed ++ [by])}

  def decided(%__MODULE__{} = call, by, {:allow, after_outside: true}) do
    call = decided(call, by, :allow)
    %{call | allowed_after_outside: Enum.uniq(call.allowed_after_outside ++ [by])}
  end

  def decided(%__MODULE__{} = call, by, {:allow, after_outside: false}),
    do: decided(call, by, :allow)

  def decided(%__MODULE__{} = call, by, {:ask, prompt}),
    do: decided(call, by, {:ask, prompt, nil})

  def decided(%__MODULE__{} = call, by, {:ask, prompt, memo}) when is_binary(prompt),
    do: %{call | asks: call.asks ++ [%Ask{by: by, prompt: prompt, memo: memo}]}

  def decided(%__MODULE__{} = call, by, {:deny, reason}) when is_binary(reason),
    do: %{call | denied: %Denial{by: by, reason: reason}}

  # -- for the runtime ---------------------------------------------------------

  @doc "Keeps `value` under `key` for Wardrik or a library built on it."
  @spec put_private(t(), atom(), term()) :: t()
  def put_private(%__MODULE__{} = call, key, value) when is_atom(key),
    do: %{call | private: Map.put(call.private, key, value)}

  @doc """
  Sets the state the hooks' answers come to: denied, waiting, or allowed. A
  gated tool's call no hook allowed by name, or one in a run that has read
  content from outside, waits on its tool.
  """
  @spec checked(t()) :: t()
  def checked(%__MODULE__{} = call) do
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
           scope: %Scope{tainted: true},
           allowed_after_outside: []
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
  then on, and a gated tool's call later in the run waits on a person unless
  a hook allowed it after outside content. A tool built with
  `Wardrik.Tool.new!/1` marks its own call; one that declares
  `c:Wardrik.Tool.outside_content?/1` has it marked.
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
        allowed_after_outside: []
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
