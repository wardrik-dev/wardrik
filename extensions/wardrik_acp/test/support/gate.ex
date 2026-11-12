defmodule WardrikACP.TestGate do
  @moduledoc """
  Middleware for tests: refuses the tool calls named in `:deny`, parks those named in `:ask` until
  they're answered by call ID, and sends the test each call it decides with the turn's labels.
  """
  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context
  alias WardrikCore.Resume

  @impl true
  def call(%Context{step: {:tool_call, call}} = context, next, opts) do
    tool = Context.tool(context, call)
    send(opts[:test], {:decided, call, Context.labels(context), tool && tool.annotations})

    cond do
      call.name in Keyword.get(opts, :deny, []) ->
        {:ok, %{context | response: {:error, "Denied."}}}

      call.name in Keyword.get(opts, :ask, []) ->
        asked(context, call, next)

      true ->
        next.(context)
    end
  end

  def call(context, next, _opts), do: next.(context)

  defp asked(%Context{resume: %Resume{input: %{} = input}} = context, call, next) do
    case Map.get(input, call.id) do
      :approve -> next.(context)
      {:deny, reason} -> {:ok, %{context | response: {:error, reason}}}
      nil -> {:park, :ask, context}
    end
  end

  defp asked(context, _call, _next), do: {:park, :ask, context}
end
