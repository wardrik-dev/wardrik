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
        case Wardrik.Credential.resolve(call, {:user, "github"}) do
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

  @optional_callbacks tool: 0, tools: 1, timeout: 0, in_doubt: 1, in_doubt: 2

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
