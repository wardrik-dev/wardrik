defmodule WardrikResearch.Test.Echo do
  @moduledoc "A capability with `echo`, a tool that answers what it's given."
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "echo",
        description: "Echoes text",
        schema: [text: [type: :string]],
        run: fn args, _context -> {:ok, Map.get(args, :text, "")} end
      )
    ]
  end
end

defmodule WardrikResearch.Test.Seen do
  @moduledoc "Middleware that tells the test which tools each model call was offered."
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%WardrikCore.Context{step: :generate, metadata: %{test: pid}} = context, next, _opts) do
    send(pid, {:offered, context.subagent, Enum.map(context.tools, & &1.name)})
    next.(context)
  end

  def call(context, next, _opts), do: next.(context)
end
