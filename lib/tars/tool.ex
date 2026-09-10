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
  Builds every tool in a list of specs.

  Raises when a spec names a module that cannot be loaded or does not implement
  this behaviour, which is a configuration error rather than a runtime one.
  """
  @spec resolve!([spec()]) :: [ReqLLM.Tool.t()]
  def resolve!(specs) when is_list(specs), do: Enum.map(specs, &resolve_one!/1)

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
