defmodule WardrikCore.Subagent.Except do
  @moduledoc false
  @behaviour Wardrik.Capability

  alias Wardrik.Context

  @impl Wardrik.Capability
  def tools(context, {capabilities, names}) do
    for entry <- capabilities,
        {module, opts} = Context.entry(entry),
        tool <- module.tools(context, opts),
        tool.name not in names,
        do: tool
  end
end
