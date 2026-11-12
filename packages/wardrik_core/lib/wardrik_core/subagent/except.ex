defmodule WardrikCore.Subagent.Except do
  @moduledoc false
  @behaviour WardrikCore.Capability

  alias WardrikCore.Context

  @impl WardrikCore.Capability
  def tools(context, {capabilities, names}) do
    for entry <- capabilities,
        {module, opts} = Context.entry(entry),
        tool <- module.tools(context, opts),
        tool.name not in names,
        do: tool
  end
end
