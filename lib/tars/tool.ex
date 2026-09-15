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
  """

  @typedoc """
  A call the model asked for, in the shape `ReqLLM.Response.classify/1`
  produces: a provider-assigned id, the tool's name, and decoded arguments.

  The id is what a host correlates against. A tool reads its own call with
  `Tars.Scope.Context.current_call/0`.
  """
  @type call() :: %{id: String.t(), name: String.t(), arguments: map()}

  @typedoc """
  How a config names a tool: a module implementing this behaviour, or a tool
  built inline.
  """
  @type spec() :: module() | ReqLLM.Tool.t()

  @doc """
  Called when a config naming this module is built, so a tool that reads
  application settings sees them as they stand then.
  """
  @callback tool() :: ReqLLM.Tool.t()

  @doc """
  How long one call may take, in milliseconds.

  Optional; `Tars.LLM.ToolRunner` has a default. Declare one for work that
  legitimately runs longer than a request — a workflow that fans out across
  subagents takes minutes, and is killed part way through otherwise.
  """
  @callback timeout() :: timeout()

  @optional_callbacks timeout: 0

  @doc """
  Builds every tool in a list of specs.

  Raises when a spec names a module that cannot be loaded or does not implement
  this behaviour, which is a configuration error rather than a runtime one.
  """
  @spec resolve!([spec()]) :: [ReqLLM.Tool.t()]
  def resolve!(specs) when is_list(specs), do: Enum.map(specs, &resolve_one!/1)

  @doc """
  The timeouts the given specs declare, by tool name.

  Takes the specs alongside what `resolve!/1` built from them, so a tool is
  only built once.
  """
  @spec timeouts([spec()], [ReqLLM.Tool.t()]) :: %{String.t() => timeout()}
  def timeouts(specs, tools) when is_list(specs) and is_list(tools) do
    specs
    |> Enum.zip(tools)
    |> Enum.flat_map(fn
      {module, tool} when is_atom(module) -> declared(module, tool)
      {_inline, _tool} -> []
    end)
    |> Map.new()
  end

  defp declared(module, tool) do
    if function_exported?(module, :timeout, 0), do: [{tool.name, module.timeout()}], else: []
  end

  defp resolve_one!(%ReqLLM.Tool{} = tool), do: tool

  defp resolve_one!(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> build!(module)
      {:error, reason} -> raise ArgumentError, "cannot load tool #{inspect(module)}: #{reason}"
    end
  end

  defp resolve_one!(other) do
    raise ArgumentError, "expected a tool module or %ReqLLM.Tool{}, got: #{inspect(other)}"
  end

  defp build!(module) do
    if function_exported?(module, :tool, 0) do
      module.tool()
    else
      raise ArgumentError, "#{inspect(module)} does not implement Tars.Tool"
    end
  end
end
