defmodule Tars.LLM do
  @moduledoc """
  Drives the LLM thinking loop for a single agent turn.
  """

  alias Tars.LLM

  defstruct [
    :config,
    :context,
    tools: []
  ]

  @type t() :: %__MODULE__{
          config: LLM.Config.t(),
          context: ReqLLM.Context.t(),
          tools: list(ReqLLM.Tool.t())
        }

  def new(opts \\ []) do
    config = Keyword.get(opts, :config, %LLM.Config{})
    context = Keyword.get(opts, :context, %ReqLLM.Context{})

    opts = Keyword.merge([config: config, context: context], opts)

    struct(__MODULE__, opts)
  end

  def test_tool() do
    {:ok, tool} =
      ReqLLM.Tool.new(
        name: "get_weather",
        description: "Gets weathr by city",
        parameter_schema: [city: [type: :string, required: true]],
        callback: fn %{city: city} -> {:ok, "Weather in #{city}: sunny"} end
      )

    tool
  end

  def add_tool(%LLM{config: config} = llm, tool) do
    new_config = %{config | tools: [tool | config.tools]}

    %{llm | config: new_config}
  end

  def append_user_message(%LLM{context: context} = llm, message) do
    user_message = ReqLLM.Context.user(message)
    new_context = ReqLLM.Context.append(context, user_message)
    %{llm | context: new_context}
  end

  def stream(%LLM{config: config, context: context} = llm) do
    with {:ok, streamed} <- ReqLLM.stream_text(config.model_spec, context, tools: config.tools),
         {:ok, response} <- process_stream(streamed, config.callback_mod),
         {:ok, handled} <- handle_response(llm, response) do
      %{llm | context: handled.context}
    else
      {:error, reason} ->
        IO.puts("Error streaming text: #{inspect(reason)}")
        :error
    end
  end

  defp handle_response(
         %LLM{context: context, config: config} = llm,
         %ReqLLM.Response{} = response
       ) do
    case ReqLLM.Response.classify(response) do
      %{type: :final_answer, text: text} ->
        IO.puts("Final answer: #{text}")
        {:ok, llm}

      %{type: :tool_calls, tool_calls: tool_calls} ->
        IO.puts("Tool calls: #{inspect(tool_calls)}")
        new_context = ReqLLM.Context.execute_and_append_tools(context, tool_calls, config.tools)
        llm = %{llm | context: new_context}
        {:ok, llm}
    end
  end

  defp process_stream(streamed, callback_mod) do
    streamed
    |> ReqLLM.StreamResponse.process_stream(
      on_chunk: &callback_mod.handle_chunk/1,
      on_meta: &callback_mod.handle_meta/1,
      on_result: &callback_mod.handle_result/1,
      on_thinking: &callback_mod.handle_thinking/1,
      on_tool_call: &callback_mod.handle_tool_call/1
    )
  end
end
