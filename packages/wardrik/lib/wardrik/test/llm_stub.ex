defmodule Wardrik.Test.LLMStub do
  @moduledoc """
  Feeds canned responses to the turn loop.

  Each call to the stream is answered with the next response in the list, and
  every stream callback is invoked on the way, so the publishing path runs too.

  The responses are stubbed with Mimic, which a suite using this depends on
  and starts, having copied `ReqLLM` and `ReqLLM.StreamResponse`:

      Mimic.copy(ReqLLM)
      Mimic.copy(ReqLLM.StreamResponse)
  """

  @compile {:no_warn_undefined, Mimic}

  @doc "Answers successive turn iterations with `responses`, in order."
  def stream(responses) when is_list(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Mimic.stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
      opts[:on_chunk].("chunk")
      opts[:on_meta].(%{tokens: 1})
      opts[:on_thinking].("thinking")
      opts[:on_result].("result")
      opts[:on_tool_call].(%{name: "echo"})

      Agent.get_and_update(agent, fn [head | rest] -> {{:ok, head}, rest} end)
    end)
  end

  @doc """
  Answers each turn according to what it was asked.

  `fun` receives `%{prompt: prompt, system: system, tools: tool_names, model:
  model_spec}` and returns a response the way `stream/1` does. Nothing is
  shared between turns, so concurrent turns stay deterministic where an
  ordered list of responses would race.
  """
  def answering(fun) when is_function(fun, 1) do
    Mimic.stub(ReqLLM, :stream_text, fn model, context, opts ->
      asked = %{
        prompt: prompt(context),
        system: opts[:system_prompt],
        tools: Enum.map(opts[:tools], & &1.name),
        model: model
      }

      {:ok, {:asked, asked}}
    end)

    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn {:asked, asked}, opts ->
      opts[:on_result].("...")
      fun.(asked)
    end)
  end

  @doc """
  Answers each request with the response at the index of the assistant
  messages its context already holds, every tool call in it given an id no
  earlier request was given, as a provider does.

  A turn replayed from a checkpoint asks nothing, so its calls keep the ids
  they had; a model asked again gets new ones, so a ledger keyed by call id
  cannot take the one for the other.
  """
  def by_round(responses) when is_list(responses) do
    Mimic.stub(ReqLLM, :stream_text, fn _model, context, _opts ->
      {:ok, {:round, Enum.count(context.messages, &(&1.role == :assistant))}}
    end)

    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn {:round, round}, opts ->
      opts[:on_result].("result")
      {:ok, fresh_ids(Enum.at(responses, round, List.last(responses)))}
    end)
  end

  defp fresh_ids(%ReqLLM.Response{message: %{tool_calls: [_ | _] = calls} = message} = response) do
    asked = System.unique_integer([:positive])
    calls = Enum.map(calls, &%{&1 | id: "#{&1.id}_#{asked}"})

    %{response | message: %{message | tool_calls: calls}}
  end

  defp fresh_ids(response), do: response

  @doc "The text of the last user message in a context."
  def prompt(%ReqLLM.Context{} = context) do
    context.messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :user, content: content} -> text(content)
      _message -> nil
    end)
  end

  defp text(content) when is_binary(content), do: content

  defp text(parts) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join(& &1.text)
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
