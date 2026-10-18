defmodule Wardrik.Tool do
  @moduledoc """
  A tool an agent may call, and the behaviour of a module that builds one.

  A tool is a `t:t/0`: a name, a description, a schema for its arguments,
  and what it runs. `new!/1` builds one.

  Wardrik ships no tools of its own but the catalog's, which offer an agent
  `Wardrik`'s functions on itself and on the agents of its owner, through
  `Wardrik.Catalog.Self` and `Wardrik.Catalog.Agents`. Implement this behaviour in your own
  application or in a tool package, then name the module in a config:

      Wardrik.LLM.Config.new(tools: [MyApp.Tools.SearchIssues])

  A tool is handed its arguments, validated against its schema, and a
  `Wardrik.Tool.Context`: the run the call runs under, the call's id and
  idempotency key, the credentials its annotations named, and a way to
  report progress. It answers as `t:answer/0` says:

      defmodule MyApp.Tools.SearchIssues do
        @behaviour Wardrik.Tool

        @impl true
        def tool do
          Wardrik.Tool.new!(
            name: "search_issues",
            description: "Search this user's GitHub issues.",
            schema: [query: [type: :string, required: true, doc: "What to find"]],
            run: {__MODULE__, :run, []}
          )
        end

        @impl true
        def annotations(_name), do: %{credentials: ["github"], labels: ["outside"]}

        def run(%{query: query}, %Wardrik.Tool.Context{credentials: %{"github" => github}}) do
          case search(query, github) do
            {:ok, issues} -> Wardrik.Tool.Result.ok(issues)
            {:error, :unauthorized} -> {:refused, "github"}
            {:error, reason} -> Wardrik.Tool.Result.error(reason)
          end
        end
      end

  ## Answering

  A tool answers with `{:ok, result}`, `{:error, reason}`, or
  `Wardrik.Tool.Result.ok/1` and `error/1` for the difference between a tool
  that failed and a call that did, and in four more ways; see `t:answer/0`.

  Parking a call, `{:park, prompt}`, stops the turn instead of answering it,
  and the prompt is what a person is shown. What parking is for is work that
  cannot finish until something outside the turn happens. Approving a parked
  call hands the tool its arguments again, so a tool that parks must be safe
  to call twice.

  A tool that cannot say how a call ended, because what it reached went
  quiet part way, answers `{:in_doubt, reason}` rather than an error: the
  model would retry an error under a new idempotency key, and the effect
  might happen twice. The call runs again under the same key where the
  tool's annotations say it may, and waits on a person otherwise; see
  `Wardrik.Call.Pipeline`.

  ## Sources

  A module that implements `c:tools/1` is a source: one spec, however many
  tools it has to give. It is named with an argument, and both travel as data:

      Wardrik.LLM.Config.new(tools: [{MyPack.Servers, :github}])

  A source is asked for its tools every time a turn is built, so `c:tools/1`
  reads what this node already holds and never goes out to fetch it.

  ## What a tool declares

  Three optional callbacks tell the runtime about a tool's calls, each with a
  form taking a source's argument first:

    * `c:annotations/1` - what holds for every call to the tool: whether it
      is gated, what its answers hold, what a call does in doubt, how long
      one may take, and the credentials it needs; see
      `Wardrik.Tool.Annotations`
    * `c:subjects/2` - what a call acts on, from its arguments, so a rule can
      name a call by what it does: `write_file(notes/*)`
    * `c:context/1` - what the tool tells the model as each turn begins

  `c:context/1` speaks for the turn rather than a call: text put after the
  system prompt as each turn begins, such as the files `WardrikWorkspace`
  reads into it. Text with labels labels the turn from its start, as a call
  answering with it would.
  """

  alias Wardrik.Tool.Annotations

  @enforce_keys [:name, :description, :run]
  defstruct [:name, :description, :run, schema: []]

  @typedoc """
  A tool: the `name` the model calls it by, the `description` it reads to
  decide when to, the `schema` of its arguments, as `NimbleOptions` keys or a
  JSON Schema map, and what it runs; see `t:run/0`.
  """
  @type t() :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: keyword() | map(),
          run: run()
        }

  @typedoc """
  What a tool runs: `{module, function, args}`, called as
  `module.function(args..., input, context)`, or a function of the input and
  the context.
  """
  @type run() :: {module(), atom(), list()} | (map(), Wardrik.Tool.Context.t() -> answer())

  @typedoc """
  A call the model asked for, in the shape `ReqLLM.Response.classify/1`
  produces: a provider-assigned id, the tool's name, and decoded arguments.

  The id is what a host correlates against.
  """
  @type call() :: %{id: String.t(), name: String.t(), arguments: map()}

  @typedoc """
  How a config names a tool: a module implementing this behaviour, a source
  module with its argument, or a tool built inline.
  """
  @type spec() :: module() | {module(), term()} | t()

  @typedoc """
  What a tool answers.

    * `{:ok, output}` and `{:error, reason}`
    * `{:ok, output, opts}` - an answer with what the runtime records of it:
      `labels:` for what it holds, which its run carries from then on (see
      `Wardrik.Call.label/2`), `served_by:` for what answered it, which
      the call's events name (see `t:Wardrik.Call.served/0`), and `cost:`
      for what the call cost in US dollars, which its `tool_call.completed`
      event carries and a budget counts (see `t:Wardrik.Call.cost/0`)
    * `{:error, reason, cost: usd}` - a failed call that still cost `usd`
      US dollars, which its event carries and a budget counts
    * `{:park, prompt}` and `{:park, prompt, link: link}` - the call waits on
      a person, who is shown `prompt`, and authorizes at `link` where there
      is one; see `Wardrik.Call.park/3`
    * `{:in_doubt, reason}` and `{:in_doubt, reason, served_by: served}` - the
      call may have done what it does, and the tool cannot say; see above
    * `{:refused, name}` - the system the tool reaches refused the credential
      it was handed as `name`. The runtime tells the resolver, resolves it
      again, and runs the tool once more.
  """
  @type answer() ::
          {:ok, term()}
          | {:error, term()}
          | {:error, term(), [cost: number()]}
          | {:ok, term(),
             [labels: [Wardrik.Label.t()], served_by: Wardrik.Call.served(), cost: number()]}
          | {:park, String.t()}
          | {:park, String.t(), link: Wardrik.Call.Ask.link()}
          | {:in_doubt, String.t()}
          | {:in_doubt, String.t(), served_by: Wardrik.Call.served()}
          | {:refused, Wardrik.Credential.ref()}

  @doc """
  Called when a config naming this module is built, so a tool that reads
  application settings sees them as they stand then.
  """
  @callback tool() :: t()

  @doc """
  Every tool this source has, built on this node.

  Called with the argument the spec named it with, wherever a turn needs its
  tools. An empty list is a source with nothing to offer right now.
  """
  @callback tools(term()) :: [t()]

  @doc """
  What holds for every call to the tool `name`, as `Wardrik.Tool.Annotations`
  reads it. Optional; a tool that declares none has every default. A source
  answers with `c:annotations/2`.
  """
  @callback annotations(name :: String.t()) :: Annotations.t() | map() | keyword()

  @doc "`c:annotations/1` for a source, asked with the argument the spec named it with."
  @callback annotations(argument :: term(), name :: String.t()) ::
              Annotations.t() | map() | keyword()

  @doc """
  What a call to the tool `name` with `arguments` acts on: strings a rule
  that names the tool with an argument, `name(argument)`, is matched against,
  each on its own. Optional; a tool that declares none is spoken for only by
  rules naming it whole. A source answers with `c:subjects/3`.
  """
  @callback subjects(name :: String.t(), arguments :: map()) :: [String.t()]

  @doc "`c:subjects/2` for a source, asked with the argument the spec named it with."
  @callback subjects(argument :: term(), name :: String.t(), arguments :: map()) :: [String.t()]

  @typedoc """
  What a tool tells the model before a turn: text, `{text, labels}` for text
  that holds what `labels` name, such as `["outside"]` for text nobody on the
  agent's side wrote, or `nil` for nothing.
  """
  @type context() :: String.t() | {String.t(), [Wardrik.Label.t()]} | nil

  @doc """
  What the tool tells the model as each turn begins, put after the system
  prompt of every request the turn makes, asked with the turn's run, whose
  host holds the store it reads from. Optional. It is asked once, when the
  turn is built, so it reads what it needs then. One that raises fails that
  turn, which runs supervised, and the agent goes on to its next. A source
  answers with `c:context/2`.
  """
  @callback context(Wardrik.Run.t()) :: context()

  @doc "`c:context/1` for a source, asked with the argument the spec named it with first."
  @callback context(argument :: term(), Wardrik.Run.t()) :: context()

  @optional_callbacks tool: 0,
                      tools: 1,
                      annotations: 1,
                      annotations: 2,
                      subjects: 2,
                      subjects: 3,
                      context: 1,
                      context: 2

  @doc """
  A tool, from `:name`, `:description`, `:schema` and `:run`; see `t:t/0`.

  Raises on a field missing or unknown, and on a name or schema no model
  could be offered.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    tool = struct!(__MODULE__, opts)
    _offered = Wardrik.LLM.Tools.to_req_llm(tool)
    tool
  end

  @doc """
  Builds every tool in a list of specs, in the order they are named.

  Raises when a spec names a module that cannot be loaded or does not implement
  this behaviour, which is a configuration error rather than a runtime one.
  """
  @spec resolve!([spec()]) :: [t()]
  def resolve!(specs) when is_list(specs), do: Enum.flat_map(specs, &resolve_one!/1)

  @doc """
  What a spec declares holds for every call to its tool `name`, with every
  default where it declares nothing; see `Wardrik.Tool.Annotations`.
  """
  @spec annotations(spec(), String.t()) :: Annotations.t()
  def annotations(spec, name), do: Annotations.new(declared(spec, :annotations, [name]) || %{})

  @doc "What a spec says a call to its tool `name` with `arguments` acts on."
  @spec subjects(spec(), String.t(), map()) :: [String.t()]
  def subjects(spec, name, arguments) do
    case declared(spec, :subjects, [name, arguments]) do
      subjects when is_list(subjects) -> Enum.filter(subjects, &is_binary/1)
      _none -> []
    end
  end

  @doc """
  What `specs` tell the model before a turn under `run`, joined in the
  order they are named, or `nil` where none tells it anything, and the labels
  of what they tell it.
  """
  @spec context([spec()], Wardrik.Run.t()) :: {String.t() | nil, [Wardrik.Label.t()]}
  def context(specs, %Wardrik.Run{} = run) when is_list(specs) do
    told = for spec <- specs, told = told(spec, run), do: told

    case Enum.map_join(told, "\n\n", &elem(&1, 0)) do
      "" -> {nil, []}
      text -> {text, Enum.reduce(told, [], &Wardrik.Label.union(&2, elem(&1, 1)))}
    end
  end

  defp told(spec, run) do
    case declared(spec, :context, [run]) do
      {text, labels} when is_binary(text) and text != "" and is_list(labels) -> {text, labels}
      text when is_binary(text) and text != "" -> {text, []}
      _nothing -> nil
    end
  end

  # What a module declares with `function`, or a source with its argument
  # first; `nil` where it declares nothing.
  defp declared({module, argument}, function, args) when is_atom(module) do
    if exports?(module, function, length(args) + 1),
      do: apply(module, function, [argument | args])
  end

  defp declared(module, function, args) when is_atom(module) do
    if exports?(module, function, length(args)), do: apply(module, function, args)
  end

  defp declared(%__MODULE__{}, _function, _args), do: nil

  @doc """
  The call with what `spec`, the spec that builds its tool, declares written
  on it, before any hook reads it: whether it is gated, and what it acts on.
  A call to a tool its run's config does not name, `nil`, is left as it is.
  """
  @spec declared(Wardrik.Call.t(), spec() | nil) :: Wardrik.Call.t()
  def declared(%Wardrik.Call{} = call, nil), do: call

  def declared(%Wardrik.Call{target: %Wardrik.Call.Tool{name: name} = target} = call, spec) do
    gated = annotations(spec, name).gated
    subjects = subjects(spec, name, target.arguments)
    %{call | target: %{target | gated: gated, subjects: subjects}}
  end

  @doc "Whether this node can build the tools a spec names."
  @spec available?(spec()) :: boolean()
  def available?(%__MODULE__{}), do: true

  def available?({module, _argument}) when is_atom(module), do: exports?(module, :tools, 1)

  def available?(module) when is_atom(module), do: exports?(module, :tool, 0)

  @doc """
  Whether a spec can be written down and read back on another node.

  A module and a source travel as the data that names them, and build their
  tools again where they are read. A tool given inline does not.
  """
  @spec travels?(spec()) :: boolean()
  def travels?(%__MODULE__{}), do: false
  def travels?(_named), do: true

  @doc "The names of the tools a spec builds."
  @spec names(spec()) :: [String.t()]
  def names(spec), do: Enum.map(resolve!([spec]), & &1.name)

  defp resolve_one!(%__MODULE__{} = tool), do: [tool]

  defp resolve_one!({module, argument}) when is_atom(module) do
    if available?({module, argument}) do
      module.tools(argument)
    else
      raise ArgumentError,
            "#{inspect(module)} cannot be loaded or does not implement Wardrik.Tool tools/1"
    end
  end

  defp resolve_one!(module) when is_atom(module) do
    if available?(module) do
      [module.tool()]
    else
      raise ArgumentError,
            "#{inspect(module)} cannot be loaded or does not implement Wardrik.Tool"
    end
  end

  defp resolve_one!(other) do
    raise ArgumentError,
          "expected a tool module, a source, or %Wardrik.Tool{}, got: #{inspect(other)}"
  end

  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
