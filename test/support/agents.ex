defmodule Wardrik.Test.Tools do
  @moduledoc "A capability with two tools: `echo`, and `inbox`, which needs a sign-in."
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "echo",
        description: "Echoes text",
        schema: [text: [type: :string]],
        run: fn args, _context -> {:ok, Map.get(args, :text, "")} end
      ),
      WardrikCore.Tool.new!(
        name: "inbox",
        description: "Reads the inbox",
        schema: [],
        run: fn _args, _context -> {:ok, "Nothing new."} end
      )
    ]
  end
end

defmodule Wardrik.Test.Approval do
  @moduledoc "Middleware that parks each `echo` call until a person answers, and `inbox` on a sign-in."
  @behaviour WardrikCore.Middleware

  alias WardrikCore.Authorization
  alias WardrikCore.Context
  alias WardrikCore.Resume

  @impl true
  def call(
        %Context{step: {:tool_call, call}, resume: %Resume{input: input}} = context,
        next,
        _opts
      )
      when is_map(input) do
    case Map.get(input, call.id) do
      {:deny, reason} -> {:ok, %{context | response: {:error, reason}}}
      _approved -> next.(context)
    end
  end

  def call(%Context{step: {:tool_call, %{name: "inbox"}}} = context, _next, _opts),
    do: {:park, %Authorization{url: "https://example.com/sign-in", credential: "mail"}, context}

  def call(%Context{step: {:tool_call, _call}} = context, _next, _opts),
    do: {:park, %{interrupt: "tool_approval", message: "Run echo?"}, context}

  def call(context, next, _opts), do: next.(context)
end

defmodule Wardrik.Test.LLM do
  @moduledoc "Model answers the tests stub ReqLLM with."

  def answer(text), do: response(ReqLLM.Context.assistant(text))
  def calling(calls), do: response(ReqLLM.Context.assistant("", tool_calls: calls))
  def call(id, name, args), do: ReqLLM.ToolCall.new(id, name, JSON.encode!(args))

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
end
