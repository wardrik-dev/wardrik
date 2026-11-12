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
  @moduledoc "Middleware that parks each `echo` call until a person answers it, and `inbox` on a sign-in."
  @behaviour WardrikCore.Middleware

  alias WardrikCore.Authorization
  alias WardrikCore.Context
  alias WardrikCore.Resume

  @impl true
  def call(%Context{step: {:tool_call, call}} = context, next, _opts) do
    case answer(context, call) do
      nil -> park(context, call)
      {:deny, reason} -> {:ok, %{context | response: {:error, reason}}}
      _approved -> next.(context)
    end
  end

  def call(context, next, _opts), do: next.(context)

  defp answer(%Context{resume: %Resume{input: input}}, call) when is_map(input),
    do: Map.get(input, call.id)

  defp answer(_context, _call), do: nil

  defp park(context, %{name: "inbox"}),
    do: {:park, %Authorization{url: "https://example.com/sign-in", credential: "mail"}, context}

  defp park(context, _call),
    do: {:park, %{interrupt: "tool_approval", message: "Run echo?"}, context}
end

defmodule Wardrik.Test.LLM do
  @moduledoc "Model answers the tests stub ReqLLM with."

  def answer(text), do: response(ReqLLM.Context.assistant(text))
  def calling(calls), do: response(ReqLLM.Context.assistant("", tool_calls: calls))
  def call(id, name, args), do: ReqLLM.ToolCall.new(id, name, JSON.encode!(args))

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
end

defmodule Wardrik.Test.Mail do
  @moduledoc "A capability with `mail`, a tool that reads the inbox with the principal's `mail` credential."
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "mail",
        description: "Reads the inbox",
        schema: [],
        run: fn _args, context ->
          with {:ok, token} <- WardrikCore.Credentials.fetch(context, "mail"),
               do: {:ok, "Read with #{token}."}
        end
      )
    ]
  end
end

defmodule Wardrik.Test.Blocking do
  @moduledoc "A capability with `block`, a tool that tells the test it runs, and waits to be released."
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, test) do
    [
      WardrikCore.Tool.new!(
        name: "block",
        description: "Blocks until released",
        schema: [],
        run: fn _args, %{step: {:tool_call, call}} ->
          send(test, {:running, call.id, self()})
          receive do: (:release -> {:ok, "released"})
        end
      )
    ]
  end
end

defmodule Wardrik.Test.Tell do
  @moduledoc "Middleware that tells the test of each model call, for the deployment's middleware."
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%WardrikCore.Context{step: :generate, agent_id: id} = context, next, test) do
    send(test, {:middleware, id})
    next.(context)
  end

  def call(context, next, _test), do: next.(context)
end
