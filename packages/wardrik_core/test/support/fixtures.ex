defmodule WardrikCore.Test.Echo do
  @moduledoc false
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "echo",
        description: "Echoes text",
        schema: [text: [type: :string]],
        run: fn args, _context -> {:ok, Map.get(args, :text, "")} end,
        annotations: [idempotent: true]
      )
    ]
  end
end

defmodule WardrikCore.Test.ParkTools do
  @moduledoc false
  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context

  @impl true
  def call(
        %Context{
          step: {:tool_call, call},
          resume: %WardrikCore.Resume{reason: :needs_approval, input: input}
        } = context,
        next,
        _opts
      ) do
    case Map.get(input, call.id) do
      :approve -> next.(context)
      {:deny, reason} -> {:error, reason}
      nil -> {:park, :needs_approval, context}
    end
  end

  def call(%Context{step: {:tool_call, _}} = context, _next, _opts),
    do: {:park, :needs_approval, context}

  def call(context, next, _opts), do: next.(context)
end

defmodule WardrikCore.Test.ParkGenerate do
  @moduledoc false
  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context

  @impl true
  def call(
        %Context{step: :generate, resume: %WardrikCore.Resume{reason: :spend?, input: :ok}} =
          context,
        next,
        _opts
      ),
      do: next.(context)

  def call(%Context{step: :generate} = context, _next, _opts), do: {:park, :spend?, context}
  def call(context, next, _opts), do: next.(context)
end

defmodule WardrikCore.Test.LLM do
  @moduledoc false

  def answer(text), do: response(ReqLLM.Context.assistant(text))
  def calling(calls), do: response(ReqLLM.Context.assistant("", tool_calls: calls))

  def call(id, name, args \\ %{}), do: ReqLLM.ToolCall.new(id, name, JSON.encode!(args))

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
end
