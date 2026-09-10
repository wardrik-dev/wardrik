defmodule Tars.Test.LLMStub do
  @moduledoc """
  Feeds canned responses to the turn loop.

  Each call to the stream is answered with the next response in the list, and
  every stream callback is invoked on the way, so the publishing path runs too.
  """

  import Mimic

  @doc "Answers successive turn iterations with `responses`, in order."
  def stream(responses) when is_list(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

    stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
      opts[:on_chunk].("chunk")
      opts[:on_meta].(%{tokens: 1})
      opts[:on_thinking].("thinking")
      opts[:on_result].("result")
      opts[:on_tool_call].(%{name: "echo"})

      Agent.get_and_update(agent, fn [head | rest] -> {{:ok, head}, rest} end)
    end)
  end

  @doc "A response the loop treats as a final answer."
  def final_answer(text), do: response(ReqLLM.Context.assistant(text), :stop)

  @doc "A response asking for one tool call."
  def tool_call(id, name, arguments) do
    # `valid_call?/1` in ToolExchange requires arguments as a JSON string.
    call = ReqLLM.ToolCall.new(id, name, JSON.encode!(arguments))
    response(ReqLLM.Context.assistant("", tool_calls: [call]), :tool_calls)
  end

  @doc "A raw response with the given message and finish reason."
  def response(message, finish_reason) do
    %ReqLLM.Response{
      id: "resp_1",
      model: "test",
      context: ReqLLM.Context.new(),
      message: message,
      finish_reason: finish_reason
    }
  end
end
