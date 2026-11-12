defmodule Wardrik.Test.Priced do
  @moduledoc "A capability with `search`, a tool that costs a cent a call."
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "search",
        description: "Searches",
        schema: [],
        run: fn _args, context ->
          {:ok, "Found it.", WardrikCore.Context.measure(context, :usd, 0.01)}
        end
      )
    ]
  end
end

defmodule Wardrik.Test.Delegating do
  @moduledoc "A capability with `delegate`, a tool that hands its task to a subagent."
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "delegate",
        description: "Delegates",
        schema: [],
        run: fn _args, context ->
          {:ok, answer, measured} =
            WardrikCore.subagent(context, "Do it", except_tools: ["delegate"])

          {:ok, answer.text, WardrikCore.Context.measure(context, measured)}
        end
      )
    ]
  end
end
