defmodule Tars.LLM do
  @moduledoc """
  Drives the LLM thinking loop for a single agent turn.
  """

  require Logger

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

  def test_tools() do
    {:ok, weather_tool} =
      ReqLLM.Tool.new(
        name: "get_weather",
        description: "Gets weathr by city",
        parameter_schema: [city: [type: :string, required: true]],
        callback: fn %{city: city} -> {:ok, "Weather in #{city}: sunny"} end
      )

    {:ok, addition_tool} =
      ReqLLM.Tool.new(
        name: "add_numbers",
        description: "Adds two numbers together",
        parameter_schema: [
          a: [type: :integer, required: true],
          b: [type: :integer, required: true]
        ],
        callback: fn %{a: a, b: b} -> {:ok, a + b} end
      )

    [
      weather_tool,
      addition_tool
    ]
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

  def stream(%LLM{config: config, context: context} = llm, subscriber \\ self()) do
    with {:ok, streamed} <- ReqLLM.stream_text(config.model_spec, context, tools: llm.tools),
         {:ok, response} <- process_stream(streamed, subscriber),
         {:ok, handled} <- handle_response(llm, response) do
      %{llm | context: handled.context}
    else
      {:error, reason} ->
        Logger.warning("Error streaming text: #{inspect(reason)}")
        :error
    end
  end

  defp handle_response(%LLM{context: context} = llm, %ReqLLM.Response{} = response) do
    case ReqLLM.Response.classify(response) do
      %{type: :final_answer, text: text} ->
        Logger.debug("Final answer: #{text}")
        {:ok, llm}

      %{type: :tool_calls, tool_calls: tool_calls} ->
        Logger.debug("Tool calls: #{inspect(tool_calls)}")
        new_context = ReqLLM.Context.execute_and_append_tools(context, tool_calls, llm.tools)
        llm = %{llm | context: new_context}
        stream(llm)
        {:ok, llm}
    end
  end

  defp process_stream(streamed, subscriber_pid) do
    streamed
    |> ReqLLM.StreamResponse.process_stream(
      on_chunk: fn chunk -> send(subscriber_pid, {:chunk, chunk}) end,
      on_meta: fn meta -> send(subscriber_pid, {:meta, meta}) end,
      on_result: fn result -> send(subscriber_pid, {:result, result}) end,
      on_thinking: fn thinking -> send(subscriber_pid, {:thinking, thinking}) end,
      on_tool_call: fn tool_call -> send(subscriber_pid, {:tool_call, tool_call}) end
    )
  end
end
