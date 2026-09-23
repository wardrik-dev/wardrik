defmodule Tars.Tool do
  @moduledoc """
  A module that produces a tool an agent may call.

  Tars ships no tools of its own. Implement this behaviour in your own
  application or in a tool package, then name the module in a config:

      Tars.LLM.Config.new(tools: [MyApp.Tools.Ping])

  Prefer an MFA callback over an anonymous function, so the tool survives being
  named by a config that crosses a node boundary.

      defmodule MyApp.Tools.Ping do
        @behaviour Tars.Tool

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
  `Tars.Tool.Result.ok/1` and `error/1` for the difference between a tool that
  failed and a call that did.

  `{:park, prompt}` is the fourth answer: the call stops the turn instead of
  answering it, and the prompt is what a person is shown. What it is for is
  work that cannot finish until something outside the turn happens, such as a
  credential the user has not authorized yet:

      def run(_params) do
        scope = Tars.Scope.Context.current()

        case Tars.Credential.resolve(scope, {:user, "github"}) do
          {:ok, credential} -> search(credential)
          {:error, {:authorization_required, url}} -> {:park, "Connect GitHub: " <> url}
          {:error, reason} -> Tars.Tool.Result.error(reason)
        end
      end

  Approving a parked call runs the callback again, so a tool that parks must be
  safe to call twice.

  ## Sources

  A module that implements `c:tools/1` is a source: one spec, however many
  tools it has to give. It is named with an argument, and both travel as data:

      Tars.LLM.Config.new(tools: [{TarsMCP.Server, :github}])

  A source is asked for its tools every time a turn is built, so `c:tools/1`
  reads what this node already holds and never goes out to fetch it.
  """

  @typedoc """
  A call the model asked for, in the shape `ReqLLM.Response.classify/1`
  produces: a provider-assigned id, the tool's name, and decoded arguments.

  The id is what a host correlates against. A tool reads its own call with
  `Tars.Scope.Context.current_call/0`.
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

  Optional; `Tars.LLM.ToolRunner` has a default. Declare one for work that
  legitimately runs longer than a request — a workflow that fans out across
  subagents takes minutes, and is killed part way through otherwise.
  """
  @callback timeout() :: timeout()

  @optional_callbacks tool: 0, tools: 1, timeout: 0

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

  defp resolve_one!(%ReqLLM.Tool{} = tool), do: [tool]

  defp resolve_one!({module, argument}) when is_atom(module) do
    if available?({module, argument}) do
      module.tools(argument) |> assert_tools!(module)
    else
      raise ArgumentError,
            "#{inspect(module)} cannot be loaded or does not implement Tars.Tool tools/1"
    end
  end

  defp resolve_one!(module) when is_atom(module) do
    if available?(module) do
      [module.tool()]
    else
      raise ArgumentError, "#{inspect(module)} cannot be loaded or does not implement Tars.Tool"
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
