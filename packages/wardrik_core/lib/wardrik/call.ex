defmodule Wardrik.Call do
  @moduledoc """
  One call an agent means to make, to a tool or to a model, from the moment
  it is proposed until it has been answered.

  A call is a token, the way a `Plug.Conn` is. `Wardrik.Call.Pipeline` moves
  it through the same steps whatever it goes to: `Wardrik.Hook`s are handed it
  and say what they make of it, the runtime writes what they said on it with
  `decided/3`, and it is the same value whether it is being decided, waiting
  on a person, or answered.

  A tool is handed the call's arguments and a `Wardrik.Tool.Context`, and what
  it answers the runtime writes on the call with `answer/2`, `park/3`,
  `doubt/2`, `served/2` and `label/2`.

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
    * `:run` - the `Wardrik.Run` it runs under, `nil` while it waits

  What was said about it, written with `decided/3`:

    * `:denied` - the `Wardrik.Call.Denial` that refused it
    * `:asks` - the `Wardrik.Call.Ask`s it waits on, in the order they were asked
    * `:allowed` - the names of the hooks that allowed it by name

  What became of it, set by the runtime:

    * `:state` - see below
    * `:result` - what a tool answered, `{:ok, output}` or `{:error, reason}`,
      or how a model call ended, as `t:Wardrik.LLM.Dispatch.outcome/0`
    * `:served_by` - what answered a tool call, where its tool said, as
      `t:served/0`
    * `:cost` - what it cost, as `t:cost/0`: a model call priced from what
      it used, or a tool call at the price its tool reported, else the price
      its config lists for the tool (see `Wardrik.LLM.Config`); `nil` for one
      nobody priced
    * `:labels` - what its answer holds, as `Wardrik.Label`s; see `label/2`
    * `:note` - what the person who approved it said, which the model reads
      with its answer; see `approve/2`

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
  or on `:doubt`, when it may already have done what it does: it began before
  its agent was lost, or its tool could not say how it ended. One parked to
  resolve a credential waits on its tool, and its agent approves it once the
  credential is available; see `Wardrik.Credential.available/3`.

  ## Gated tools

  A call to a gated tool (see `Wardrik.Tool.Annotations`) goes ahead only where
  a hook allowed it by name, with `:allow`, and waits on its tool otherwise.
  A deny still refuses it and an ask still asks. A call to a tool that is not
  gated goes ahead as the hooks said, allowed by name or not. What the run it
  belongs to has read, its run's `:labels`, is for the hooks to weigh;
  `WardrikPolicy` holds a gated call after content from outside.
  """

  alias Wardrik.Call.Ask
  alias Wardrik.Call.Denial
  alias Wardrik.Call.Model
  alias Wardrik.Call.Tool
  alias Wardrik.LLM.Cost
  alias Wardrik.LLM.Request
  alias Wardrik.Run

  @enforce_keys [:id, :target]
  defstruct [
    :id,
    :target,
    :run,
    :denied,
    :result,
    :served_by,
    :cost,
    :note,
    state: :unchecked,
    asks: [],
    allowed: [],
    labels: [],
    private: %{}
  ]

  @type state() :: :unchecked | :allowed | :denied | :waiting | :approved | :done

  @typedoc """
  What answered a tool call, as its tool names it: an `:id` no other server
  shares, and a `:name` a person reads, such as a tool worker's token.
  """
  @type served() :: %{required(:id) => String.t(), optional(:name) => String.t()}

  @typedoc """
  What a call cost, in whole micro-dollars: `:provider` where the provider
  reported the figure, `:catalog` where `Wardrik.LLM.Cost` priced the tokens
  at the catalog's prices, and `:tool` where the tool reported it or the
  config lists a price for the tool.
  """
  @type cost() :: %{micro_usd: non_neg_integer(), source: :provider | :catalog | :tool}

  @typedoc """
  Who decided a call: `:hook` where hooks allowed it by name or one refused
  it, `:person` where a person answered it, `:default` where no hook named it
  and nothing asked, and `:ledger` where the ledger could not record it.
  `:hooks` are the hooks that allowed it, refused it, or asked about it.
  """
  @type decider() :: %{by: :hook | :person | :default | :ledger, hooks: [String.t()]}

  @type t() :: %__MODULE__{
          id: String.t(),
          target: Tool.t() | Model.t(),
          run: Run.t() | nil,
          state: state(),
          denied: Denial.t() | nil,
          asks: [Ask.t()],
          allowed: [String.t()],
          labels: [Wardrik.Label.t()],
          result: term(),
          served_by: served() | nil,
          cost: cost() | nil,
          note: String.t() | nil,
          private: map()
        }

  # -- building ----------------------------------------------------------------

  @doc "The call a model asked for, as `ReqLLM.Response.classify/1` gives it."
  @spec tool(Wardrik.Tool.call(), Run.t() | nil) :: t()
  def tool(%{id: id, name: name, arguments: arguments}, run \\ nil),
    do: %__MODULE__{id: id, target: %Tool{name: name, arguments: arguments}, run: run}

  @doc "The model call `request` makes."
  @spec model(Request.t(), Run.t() | nil) :: t()
  def model(%Request{} = request, run \\ nil) do
    %__MODULE__{
      id: "model_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
      target: Model.new(request),
      run: run
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
  gated tool's call no hook allowed by name waits on its tool.
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

  defp gate(_call), do: nil

  @doc """
  Marks the call's answer as holding what `labels` name, such as `"outside"`
  for a page or an issue anyone could have written; see `Wardrik.Label`. The
  run it belongs to carries them from then on. A tool's annotations name the
  labels every answer of its holds, and one handed its context labels one
  answer with `{:ok, output, labels: labels}`.
  """
  @spec label(t(), [Wardrik.Label.t()]) :: t()
  def label(%__MODULE__{} = call, labels) when is_list(labels),
    do: %{call | labels: Wardrik.Label.union(call.labels, labels)}

  @doc """
  Parks a call a tool was handed: it waits on a person, who is shown `prompt`,
  and the tool is handed it again once they approve.

  `link:` is where the person authorizes, `%{url: url, code: code}`. It is
  kept apart from the prompt: `prompt/1` never holds it, and it is shown only
  where the person answering is, never in an event log or a notice.
  `credential:` is the credential the runtime parked the call to resolve, as
  `%{ref: ref, owner: owner}`: its agent approves the call once
  `Wardrik.Credential.available/3` says the credential can be resolved.
  """
  @spec park(t(), String.t(), link: Ask.link(), credential: Ask.credential() | nil) :: t()
  def park(%__MODULE__{} = call, prompt, opts \\ []) when is_binary(prompt) do
    ask = %Ask{
      by: :tool,
      prompt: prompt,
      link: linked(Keyword.get(opts, :link)),
      credential: Keyword.get(opts, :credential)
    }

    %{call | state: :waiting, asks: [ask]}
  end

  defp linked(nil), do: nil
  defp linked(%{url: url} = link) when is_binary(url), do: Map.put_new(link, :code, nil)

  @doc "Where the person a waiting call asks authorizes, where its tool said."
  @spec link(t()) :: Ask.link() | nil
  def link(%__MODULE__{asks: asks}), do: Enum.find_value(asks, & &1.link)

  @doc "Whether the call waits on `ref` being resolvable for `owner`; see `Wardrik.Credential.available/3`."
  @spec awaits?(t(), Wardrik.Credential.ref(), Wardrik.Credential.owner()) :: boolean()
  def awaits?(%__MODULE__{state: :waiting, asks: asks}, ref, owner),
    do: Enum.any?(asks, &(&1.credential == %{ref: ref, owner: owner}))

  def awaits?(%__MODULE__{}, _ref, _owner), do: false

  @doc """
  The call waiting on `by`, `:tool` or `:doubt`, which asks `prompt`. What
  was asked of it before, and approved, is behind it.
  """
  @spec wait(t(), :tool | :doubt, String.t()) :: t()
  def wait(%__MODULE__{} = call, by, prompt) when by in [:tool, :doubt] and is_binary(prompt),
    do: %{call | state: :waiting, asks: [%Ask{by: by, prompt: prompt}]}

  @doc """
  The call waiting on a person because it may already have done what it
  does, for `reason`: approving it runs it again under the same idempotency
  key, and refusing it tells the model it may have run.
  """
  @spec doubt(t(), String.t()) :: t()
  def doubt(%__MODULE__{} = call, reason) when is_binary(reason) do
    wait(
      call,
      :doubt,
      "#{name(call)} may already have done what it does. #{reason} " <>
        "Approve to run it again, or deny to tell the agent it may have run."
    )
  end

  @doc """
  The call refused, with `reason`, by `by`: `:person` unless given, or
  `:ledger` for a call the ledger could not record.
  """
  @spec refuse(t(), :person | :ledger, String.t()) :: t()
  def refuse(%__MODULE__{} = call, by \\ :person, reason)
      when by in [:person, :ledger] and is_binary(reason),
      do: %{call | state: :denied, denied: %Denial{by: by, reason: reason}}

  @doc """
  The call a person approved, with what they said in `note`, if anything,
  which the model reads beside the call's answer. The call runs as it was
  proposed whatever the note says.
  """
  @spec approve(t(), String.t() | nil) :: t()
  def approve(%__MODULE__{state: :waiting} = call, note \\ nil)
      when is_binary(note) or is_nil(note),
      do: %{call | state: :approved, note: note}

  @doc "The call as it was proposed, to be asked about again."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = call),
    do: %{
      call
      | state: :unchecked,
        denied: nil,
        asks: [],
        allowed: [],
        note: nil
    }

  @doc """
  The call answered with `result`: a tool's `{:ok, output}` or
  `{:error, reason}`, or how a model call ended, as
  `t:Wardrik.LLM.Dispatch.outcome/0`.
  """
  @spec answer(t(), term()) :: t()
  def answer(%__MODULE__{} = call, result), do: %{call | state: :done, result: result}

  @doc """
  A model call that used `usage` of `model_spec`, the model it reached, and
  cost what `Wardrik.LLM.Cost.price/2` makes of that.
  """
  @spec used(t(), map(), term()) :: t()
  def used(%__MODULE__{target: %Model{} = model} = call, usage, model_spec),
    do: %{call | target: %{model | usage: usage}, cost: Cost.price(model_spec, usage)}

  @doc "A tool call its tool said cost `usd` dollars, or one it said nothing of, for `nil`."
  @spec priced(t(), number() | nil) :: t()
  def priced(%__MODULE__{} = call, nil), do: call

  def priced(%__MODULE__{target: %Tool{}} = call, usd) when is_number(usd) and usd >= 0,
    do: %{call | cost: %{micro_usd: Cost.micro(usd), source: :tool}}

  @doc "A tool call answered by `served_by`, where its tool named what answered it."
  @spec served(t(), served() | nil) :: t()
  def served(%__MODULE__{} = call, served_by), do: %{call | served_by: served_by}

  @doc "The call under `run`, or under none for one that is written down."
  @spec under(t(), Run.t() | nil) :: t()
  def under(%__MODULE__{} = call, run), do: %{call | run: run}

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

  @doc "Whether a hook, rather than its tool or a doubt, asked about the call."
  @spec asked_by_hook?(t()) :: boolean()
  def asked_by_hook?(%__MODULE__{asks: asks}), do: Enum.any?(asks, &is_binary(&1.by))

  @doc "Who decided a call that went ahead or was refused; see `t:decider/0`."
  @spec decided_by(t()) :: decider()
  def decided_by(%__MODULE__{denied: %Denial{by: :ledger}}), do: %{by: :ledger, hooks: []}

  def decided_by(%__MODULE__{denied: %Denial{by: :person}} = call),
    do: %{by: :person, hooks: asking(call)}

  def decided_by(%__MODULE__{denied: %Denial{by: hook}}), do: %{by: :hook, hooks: [hook]}

  def decided_by(%__MODULE__{asks: [_ | _]} = call), do: %{by: :person, hooks: asking(call)}
  def decided_by(%__MODULE__{allowed: []}), do: %{by: :default, hooks: []}
  def decided_by(%__MODULE__{allowed: allowed}), do: %{by: :hook, hooks: allowed}

  defp asking(%__MODULE__{asks: asks}), do: for(%Ask{by: by} <- asks, is_binary(by), do: by)

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
