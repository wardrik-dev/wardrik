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
