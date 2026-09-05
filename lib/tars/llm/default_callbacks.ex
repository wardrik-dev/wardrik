defmodule Tars.LLM.DefaultCallbacks do
  def handle_chunk(_chunk) do
    # IO.inspect(chunk, label: "Chunk")
  end

  def handle_meta(_meta) do
    # IO.inspect(meta, label: "Meta")
  end

  def handle_result(result) do
    IO.write(result)
  end

  def handle_thinking(thinking) do
    IO.write(thinking)
  end

  def handle_tool_call(_tool_call) do
    # IO.inspect(tool_call, label: "Tool Call")
  end
end
