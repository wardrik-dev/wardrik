defmodule Wardrik.EventLog.Test.Sink do
  @moduledoc "An events sink that sends each event to the process its options name."
  @behaviour WardrikCore.Events

  @impl true
  def handle_event(event, test), do: send(test, {:event, event})
end

defmodule Wardrik.EventLog.Test.Echo do
  @moduledoc "A capability with one tool, `echo`."
  @behaviour Wardrik.Capability

  @impl true
  def tools(_context, _opts) do
    [
      Wardrik.Tool.new!(
        name: "echo",
        description: "Echoes text",
        schema: [text: [type: :string]],
        run: fn args, _context -> {:ok, Map.get(args, :text, "")} end
      )
    ]
  end
end

defmodule Wardrik.EventLog.Test.LLM do
  @moduledoc "Model answers the tests stub ReqLLM with."

  def answer(text), do: response(ReqLLM.Context.assistant(text))
  def calling(calls), do: response(ReqLLM.Context.assistant("", tool_calls: calls))
  def call(id, name, args), do: ReqLLM.ToolCall.new(id, name, JSON.encode!(args))

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
end
