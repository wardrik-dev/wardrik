defmodule Wardrik.Tool do
  @moduledoc """
  A module that produces a tool an agent may call.

  Wardrik ships no tools of its own. Implement this behaviour in your own
  application or in a tool package, then name the module in a config:

      Wardrik.LLM.Config.new(tools: [MyApp.Tools.Ping])

  Prefer an MFA callback over an anonymous function, so the tool survives being
  named by a config that crosses a node boundary.

      defmodule MyApp.Tools.Ping do
        @behaviour Wardrik.Tool

        @impl true
        def tool do
          ReqLLM.Tool.new!(
            name: "ping",
            description: "Check whether a host answers.",
            parameter_schema: [host: [type: :string, required: true, doc: "Host to reach"]],
            callback: {__MODULE__, :run}
          )
        end

        def run(%{host: host}), do: {:ok, %{"reachable" => reachable?(host)}}
      end

  ## Answering

  A callback answers with `{:ok, result}`, `{:error, reason}`, or
  `Wardrik.Tool.Result.ok/1` and `error/1` for the difference between a tool that
  failed and a call that did.

  ## Handed the call

  A tool that needs to know who it works for, or which call it is answering,
  is built with `new!/1` and a `:call` in place of a `:callback`. It is handed
  the `Wardrik.Call` itself, under the scope it runs in and with its arguments
  validated, and answers it with `Wardrik.Call.answer/2`.

  Or it parks it, with `Wardrik.Call.park/2`: the call stops the turn instead of
  being answered, and the prompt is what a person is shown. What parking is
  for is work that cannot finish until something outside the turn happens,
  such as a credential the user has not authorized yet:

      def tool do
        Wardrik.Tool.new!(
          name: "search_issues",
          description: "Search this user's GitHub issues.",
          parameter_schema: [query: [type: :string, required: true, doc: "What to find"]],
          call: {__MODULE__, :run}
        )
      end

      def run(%Wardrik.Call{target: %Wardrik.Call.Tool{arguments: args}} = call) do
        case Wardrik.Credential.resolve(call, "github") do
          {:ok, credential} -> Wardrik.Call.answer(call, search(credential, args.query))
          {:error, {:authorization_required, url}} -> Wardrik.Call.park(call, "Connect GitHub: " <> url)
          {:error, reason} -> Wardrik.Call.answer(call, Wardrik.Tool.Result.error(reason))
        end
      end

  Approving a parked call hands the tool the call again, so a tool that parks
  must be safe to call twice.

  ## Sources

  A module that implements `c:tools/1` is a source: one spec, however many
  tools it has to give. It is named with an argument, and both travel as data:

      Wardrik.LLM.Config.new(tools: [{MyPack.Servers, :github}])

  A source is asked for its tools every time a turn is built, so `c:tools/1`
  reads what this node already holds and never goes out to fetch it.

  ## What a tool says about its calls

  Three optional callbacks tell the runtime about a call before and after it
  runs, each with a form taking a source's argument first:

    * `c:gated?/1` - its calls wait on a person unless a hook allows them by
      name, as `WardrikPolicy`'s `allow` rules do; `default: allow` is not
      enough. For a tool whose call cannot be taken back.
    * `c:subjects/2` - what a call acts on, from its arguments, so a rule can
      name a call by what it does: `write_file(notes/*)`.
    * `c:outside_content?/1` - what it answers holds content nobody on the
      agent's side wrote, such as a web page, so a call to it taints its run,
      and a gated tool's call later in the run waits on a person however its
      hooks allowed it. A tool built with `new!/1` can instead mark one call
      with `Wardrik.Call.taint/1`.

  ## What a tool tells the model first

  `c:context/0`, also optional, speaks for the turn rather than a call: text
  put after the system prompt as each turn begins, such as the files
  `WardrikWorkspace` reads into it. Text from outside taints the turn from its
  start, as a call answering with it would.
  """

  @typedoc """
  A call the model asked for, in the shape `ReqLLM.Response.classify/1`
  produces: a provider-assigned id, the tool's name, and decoded arguments.

  The id is what a host correlates against. A tool built with `new!/1` is
  handed its own call, as a `Wardrik.Call`.
  """
  @type call() :: %{id: String.t(), name: String.t(), arguments: map()}

  @typedoc """
  How a config names a tool: a module implementing this behaviour, a source
  module with its argument, or a tool built inline.
  """
  @type spec() :: module() | {module(), term()} | ReqLLM.Tool.t()

  @doc """
  Called when a config naming this module is built, so a tool that reads
  application settings sees them as they stand then.
  """
  @callback tool() :: ReqLLM.Tool.t()

  @doc """
  Every tool this source has, built on this node.

  Called with the argument the spec named it with, wherever a turn needs its
  tools. An empty list is a source with nothing to offer right now.
  """
  @callback tools(term()) :: [ReqLLM.Tool.t()]

  @doc """
  How long one call may take, in milliseconds.

  Optional; `Wardrik.LLM.ToolRunner` has a default. Declare one for work that
  legitimately runs longer than a request — a workflow that fans out across
  subagents takes minutes, and is killed part way through otherwise.
  """
  @callback timeout() :: timeout()

  @doc """
  What a call to the tool `name` does when its turn is replayed and the ledger
  holds it as begun and never finished, so whether it had its effect is not
  known: `:ask`, the default, parks it for a person, and `:rerun` runs it
  again under the same `Wardrik.Ledger.idempotency_key/2`.

  Optional. Declare `:rerun` for a tool that passes that key on to the system
  it calls, or that changes nothing, so running it again has no second
  effect. A source answers with `c:in_doubt/2` instead.
  """
  @callback in_doubt(name :: String.t()) :: :ask | :rerun

  @doc """
  `c:in_doubt/1` for a source: what a call to its tool `name` does in doubt,
  asked with the argument the spec named the source with, as `c:tools/1` is.
  """
  @callback in_doubt(argument :: term(), name :: String.t()) :: :ask | :rerun

  @doc """
  Whether a call to the tool `name` waits on a person unless a hook allows it
  by name, with an `:allow` decision; see `t:Wardrik.Hook.decision/0`. Optional,
  and `false` unless declared.
  A source answers with `c:gated?/2`.
  """
  @callback gated?(name :: String.t()) :: boolean()

  @doc "`c:gated?/1` for a source, asked with the argument the spec named it with."
  @callback gated?(argument :: term(), name :: String.t()) :: boolean()

  @doc """
  What a call to the tool `name` with `arguments` acts on: strings a rule
  that names the tool with an argument, `name(argument)`, is matched against,
  each on its own. Optional; a tool that declares none is spoken for only by
  rules naming it whole. A source answers with `c:subjects/3`.
  """
  @callback subjects(name :: String.t(), arguments :: map()) :: [String.t()]

  @doc "`c:subjects/2` for a source, asked with the argument the spec named it with."
  @callback subjects(argument :: term(), name :: String.t(), arguments :: map()) :: [String.t()]

  @doc """
  Whether what the tool `name` answers holds content from outside, so a call
  to it taints the run it belongs to. Optional, and `false` unless declared.
  A source answers with `c:outside_content?/2`.
  """
  @callback outside_content?(name :: String.t()) :: boolean()

  @doc "`c:outside_content?/1` for a source, asked with the argument the spec named it with."
  @callback outside_content?(argument :: term(), name :: String.t()) :: boolean()

  @typedoc """
  What a tool tells the model before a turn: text, `{:outside, text}` for text
  nobody on the agent's side wrote, or `nil` for nothing.
  """
  @type context() :: String.t() | {:outside, String.t()} | nil

  @doc """
  What the tool tells the model as each turn begins, put after the system
  prompt of every request the turn makes. Optional. It is asked once, when the
  turn is built, so it reads what it needs then. One that raises fails that
  turn, which runs supervised, and the agent goes on to its next. A source
  answers with `c:context/1`.
  """
  @callback context() :: context()

  @doc "`c:context/0` for a source, asked with the argument the spec named it with."
  @callback context(argument :: term()) :: context()

  @optional_callbacks tool: 0,
                      tools: 1,
                      timeout: 0,
                      in_doubt: 1,
                      in_doubt: 2,
                      gated?: 1,
                      gated?: 2,
                      subjects: 2,
                      subjects: 3,
                      outside_content?: 1,
                      outside_content?: 2,
                      context: 0,
                      context: 1

  @typedoc """
  What a tool `new!/1` builds hands its call to: `{module, function, args}`,
  called as `module.function(args..., call)`, or a function of the call.
  """
  @type handler() :: {module(), atom(), list()} | (Wardrik.Call.t() -> Wardrik.Call.t())

  @doc """
  A tool handed its `Wardrik.Call`: what `ReqLLM.Tool.new!/1` takes, with `:call`
  in place of `:callback`.

  `:call` is `{module, function}`, `{module, function, args}`, or, for a tool
  built inline, a function of the call. It answers with the call it was
  handed, answered with `Wardrik.Call.answer/2` or parked with
  `Wardrik.Call.park/2`. Raises on a bad schema, as `ReqLLM.Tool.new!/1` does.
  """
  @spec new!(keyword()) :: ReqLLM.Tool.t()
  def new!(opts) when is_list(opts) do
    {handler, opts} = Keyword.pop!(opts, :call)
    ReqLLM.Tool.new!(Keyword.put(opts, :callback, {__MODULE__, :invoke, [handler(handler)]}))
  end

  defp handler({module, function}), do: {module, function, []}

  defp handler({module, function, args} = handler)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: handler

  defp handler(fun) when is_function(fun, 1), do: fun

  @doc "Hands `call` to `handler`, the one a `new!/1` tool was built with."
  @spec hand(handler(), Wardrik.Call.t()) :: term()
  def hand({module, function, args}, %Wardrik.Call{} = call),
    do: apply(module, function, args ++ [call])

  def hand(fun, %Wardrik.Call{} = call) when is_function(fun, 1), do: fun.(call)

  @doc """
  What a tool `new!/1` builds answers when something other than
  `Wardrik.LLM.ToolRunner` calls it, which has no call to hand it.
  """
  @spec invoke(handler(), map()) :: {:error, String.t()}
  def invoke(_handler, _input),
    do:
      {:error,
       "a tool built with Wardrik.Tool.new!/1 is handed its Wardrik.Call, and runs only in a turn"}

  @doc """
  Builds every tool in a list of specs, in the order they are named.

  Raises when a spec names a module that cannot be loaded or does not implement
  this behaviour, which is a configuration error rather than a runtime one.
  """
  @spec resolve!([spec()]) :: [ReqLLM.Tool.t()]
  def resolve!(specs) when is_list(specs), do: Enum.flat_map(specs, &resolve_one!/1)

  @doc "The timeout a spec declares, or `nil` when it leaves that to the runner."
  @spec timeout(spec()) :: timeout() | nil
  def timeout({module, _argument}) when is_atom(module), do: timeout(module)

  def timeout(module) when is_atom(module) do
    if exports?(module, :timeout, 0), do: module.timeout(), else: nil
  end

  def timeout(%ReqLLM.Tool{}), do: nil

  @doc "What a spec says a call to its tool `name` does in doubt: `:rerun`, or `:ask`."
  @spec in_doubt(spec(), String.t()) :: :ask | :rerun
  def in_doubt({module, argument}, name) when is_atom(module) do
    if exports?(module, :in_doubt, 2) and module.in_doubt(argument, name) == :rerun,
      do: :rerun,
      else: :ask
  end

  def in_doubt(module, name) when is_atom(module) do
    if exports?(module, :in_doubt, 1) and module.in_doubt(name) == :rerun, do: :rerun, else: :ask
  end

  def in_doubt(%ReqLLM.Tool{}, _name), do: :ask

  @doc """
  The call with what its tool declares written on it, before any hook reads
  it: whether it is gated, and what it acts on. A call to a tool its scope's
  config does not name is left as it is.
  """
  @spec declared(Wardrik.Call.t()) :: Wardrik.Call.t()
  def declared(%Wardrik.Call{target: %Wardrik.Call.Tool{name: name} = target} = call) do
    case Wardrik.LLM.Config.tool_spec(call.scope.config, name) do
      nil ->
        call

      spec ->
        gated = gated?(spec, name)
        subjects = subjects(spec, name, target.arguments)
        %{call | target: %{target | gated: gated, subjects: subjects}}
    end
  end

  @doc "Whether a spec says a call to its tool `name` waits unless a hook allows it by name."
  @spec gated?(spec(), String.t()) :: boolean()
  def gated?(spec, name), do: declared(spec, :gated?, [name]) == true

  @doc "What a spec says a call to its tool `name` with `arguments` acts on."
  @spec subjects(spec(), String.t(), map()) :: [String.t()]
  def subjects(spec, name, arguments) do
    case declared(spec, :subjects, [name, arguments]) do
      subjects when is_list(subjects) -> Enum.filter(subjects, &is_binary/1)
      _none -> []
    end
  end

  @doc "Whether a spec says what its tool `name` answers holds content from outside."
  @spec outside_content?(spec(), String.t()) :: boolean()
  def outside_content?(spec, name), do: declared(spec, :outside_content?, [name]) == true

  @doc """
  What `specs` tell the model before a turn, joined in the order they are
  named, or `nil` where none tells it anything, and whether any of it is
  content from outside.
  """
  @spec context([spec()]) :: {String.t() | nil, boolean()}
  def context(specs) when is_list(specs) do
    told = for spec <- specs, told = told(spec), do: told

    case Enum.map_join(told, "\n\n", &elem(&1, 1)) do
      "" -> {nil, false}
      text -> {text, Enum.any?(told, &(elem(&1, 0) == :outside))}
    end
  end

  defp told(spec) do
    case declared(spec, :context, []) do
      {:outside, text} when is_binary(text) and text != "" -> {:outside, text}
      text when is_binary(text) and text != "" -> {:own, text}
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

  defp declared(%ReqLLM.Tool{}, _function, _args), do: nil

  @doc "Whether this node can build the tools a spec names."
  @spec available?(spec()) :: boolean()
  def available?(%ReqLLM.Tool{}), do: true

  def available?({module, _argument}) when is_atom(module), do: exports?(module, :tools, 1)

  def available?(module) when is_atom(module), do: exports?(module, :tool, 0)

  @doc """
  Whether a spec can be written down and read back on another node.

  A module and a source travel as the data that names them. A tool built
  inline holds a callback, and does not.
  """
  @spec travels?(spec()) :: boolean()
  def travels?(%ReqLLM.Tool{}), do: false
  def travels?({module, _argument}) when is_atom(module), do: true
  def travels?(module) when is_atom(module), do: true

  @doc "The names of the tools a spec builds."
  @spec names(spec()) :: [String.t()]
  def names(spec), do: Enum.map(resolve!([spec]), & &1.name)

  @doc """
  Reports how far `call` has got, on the turn's event stream.

  Emits `{:tool_progress, call_id, name, progress, total}` under the span of
  the call, where `total` is `nil` for work with no known end.

      Wardrik.Tool.progress(call, 3, 10)
  """
  @spec progress(Wardrik.Call.t(), number(), number() | nil) :: :ok
  def progress(%Wardrik.Call{} = call, progress, total \\ nil),
    do: progress_reporter(call).(progress, total)

  @doc """
  A function that reports progress for `call`, bound to it, for a callback
  another process runs, such as a client library's progress hook.
  """
  @spec progress_reporter(Wardrik.Call.t()) :: (number(), number() | nil -> :ok)
  def progress_reporter(%Wardrik.Call{id: id, scope: %Wardrik.Scope{source: source}} = call) do
    name = Wardrik.Call.name(call)

    fn progress, total ->
      Wardrik.Event.emit(source, {:tool_progress, id, name, progress, total})
    end
  end

  defp resolve_one!(%ReqLLM.Tool{} = tool), do: [tool]

  defp resolve_one!({module, argument}) when is_atom(module) do
    if available?({module, argument}) do
      module.tools(argument) |> assert_tools!(module)
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
          "expected a tool module, a source, or %ReqLLM.Tool{}, got: #{inspect(other)}"
  end

  defp assert_tools!(tools, module) when is_list(tools) do
    Enum.each(tools, fn
      %ReqLLM.Tool{} ->
        :ok

      other ->
        raise ArgumentError, "#{inspect(module)}.tools/1 gave #{inspect(other)}, not a tool"
    end)

    tools
  end

  defp assert_tools!(other, module) do
    raise ArgumentError, "#{inspect(module)}.tools/1 gave #{inspect(other)}, not a list of tools"
  end

  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
