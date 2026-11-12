defmodule WardrikCore.InDoubt do
  @moduledoc false
  alias WardrikCore.Context
  alias WardrikCore.Resume
  alias WardrikCore.Tool
  alias WardrikCore.ToolCall

  @spec resumes([ToolCall.t()]) :: %{String.t() => Resume.t()}
  def resumes(calls), do: Map.new(calls, fn call -> {call.id, resume()} end)

  @spec check(Context.t(), ToolCall.t()) :: :run | Tool.answer()
  def check(%Context{resume: %Resume{reason: :in_doubt, input: input}} = context, call) do
    if repeatable?(Context.tool(context, call)), do: :run, else: answered(input, call)
  end

  def check(_context, _call), do: :run

  defp resume, do: %Resume{reason: :in_doubt, input: %{}}

  defp repeatable?(nil), do: true
  defp repeatable?(tool), do: Tool.repeatable?(tool)

  defp answered(input, call) when is_map(input), do: answer(Map.get(input, call.id))
  defp answered(_input, _call), do: answer(nil)

  defp answer(:approve), do: :run
  defp answer({:deny, reason}), do: {:error, reason}
  defp answer(_unanswered), do: {:park, :in_doubt}
end
