defmodule Wardrik.Testing.Model do
  @moduledoc """
  A model for tests. It serves OpenAI's Chat Completions API on a port of its own, and answers
  each call with the next answer it's given. Each test starts its own, so tests run side by side.

      model = start_supervised!({Wardrik.Testing.Model, [Wardrik.Testing.Model.text("Done.")]})

      Wardrik.new(
        endpoints: %{"test" => Wardrik.Testing.Model.endpoint(model)},
        defaults: [model: "test"]
      )

  An answer is a `ReqLLM.Response`, `{:status, code}` or `{:status, code, message}` to fail the
  call with that HTTP status, or a function. A function takes the call's request, decoded from JSON, and returns an answer.
  Answers given as a function answer every call.
  """

  # A restart would answer from the start again.
  use GenServer, restart: :temporary

  alias ReqLLM.Message.ContentPart

  @type answer() ::
          ReqLLM.Response.t()
          | {:status, pos_integer()}
          | {:status, pos_integer(), String.t()}
          | (map() -> answer())

  @doc "Starts it with `answers`: a list taken in order, or a function."
  @spec start_link([answer()] | (map() -> answer())) :: GenServer.on_start()
  def start_link(answers), do: GenServer.start_link(__MODULE__, answers)

  @doc "Returns the endpoint to give Wardrik's `:endpoints`."
  @spec endpoint(pid()) :: keyword()
  def endpoint(model) do
    port = GenServer.call(model, :port)
    [model: "vllm:test", base_url: "http://127.0.0.1:#{port}/v1"]
  end

  @doc "Adds `answers` after those left. A function answers every call from then on."
  @spec answer(pid(), [answer()] | (map() -> answer())) :: :ok
  def answer(model, answers), do: GenServer.call(model, {:add, answers})

  @doc "Returns an answer that says `text`, streamed a piece at a time where it's a list."
  @spec text(String.t() | [String.t()]) :: ReqLLM.Response.t()
  def text(pieces) when is_list(pieces) do
    content = Enum.map(pieces, &ContentPart.text/1)
    response(%ReqLLM.Message{role: :assistant, content: content})
  end

  def text(text), do: response(ReqLLM.Context.assistant(text))

  @doc "Returns an answer that calls tools, each `{id, name, args}`."
  @spec calls([{String.t(), String.t(), map()}]) :: ReqLLM.Response.t()
  def calls(calls) do
    tool_calls =
      for {id, name, args} <- calls, do: ReqLLM.ToolCall.new(id, name, JSON.encode!(args))

    response(ReqLLM.Context.assistant("", tool_calls: tool_calls))
  end

  @doc """
  Returns the messages a call sent, as `ReqLLM.Message`s: each part of their text, and each tool
  call and tool result.
  """
  @spec messages(map()) :: [ReqLLM.Message.t()]
  def messages(%{"messages" => messages}), do: Enum.map(messages, &message/1)

  defp message(message) do
    %ReqLLM.Message{
      role: String.to_existing_atom(message["role"]),
      content: content(message["content"]),
      tool_call_id: message["tool_call_id"],
      tool_calls: tool_calls(message["tool_calls"])
    }
  end

  defp content(nil), do: []
  defp content(""), do: []
  defp content(text) when is_binary(text), do: [ContentPart.text(text)]

  defp content(parts) when is_list(parts),
    do: for(%{"type" => "text", "text" => text} <- parts, do: ContentPart.text(text))

  defp tool_calls(nil), do: nil

  defp tool_calls(calls),
    do:
      for(
        %{"id" => id, "function" => %{"name" => name, "arguments" => arguments}} <- calls,
        do: ReqLLM.ToolCall.new(id, name, arguments)
      )

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}

  @impl GenServer
  def init(answers) do
    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, {:model, self()}},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false,
        # ReqLLM keeps connections open, which Bandit would wait for as it stops.
        thousand_island_options: [shutdown_timeout: 100]
      )

    {:ok, %{server: server, answers: answers}}
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(state.server)
    {:reply, port, state}
  end

  def handle_call({:add, answer}, _from, state) when is_function(answer, 1),
    do: {:reply, :ok, %{state | answers: answer}}

  def handle_call({:add, more}, _from, %{answers: answers} = state) when is_list(answers),
    do: {:reply, :ok, %{state | answers: answers ++ more}}

  def handle_call({:next, request}, _from, %{answers: answers} = state)
      when is_function(answers, 1),
      do: {:reply, answers.(request), state}

  def handle_call({:next, request}, _from, %{answers: [next | rest]} = state),
    do: {:reply, answered(next, request), %{state | answers: rest}}

  def handle_call({:next, request}, _from, %{answers: []}),
    do:
      raise(
        ArgumentError,
        "the test model has no answer left for #{inspect(request["messages"])}"
      )

  defp answered(answer, request) when is_function(answer, 1), do: answer.(request)
  defp answered(answer, _request), do: answer

  defmodule Plug do
    @moduledoc false
    import Elixir.Plug.Conn

    @spec init({:model, pid()}) :: pid()
    def init({:model, model}), do: model

    @spec call(Elixir.Plug.Conn.t(), pid()) :: Elixir.Plug.Conn.t()
    def call(conn, model) do
      {:ok, body, conn} = read_body(conn, length: 100_000_000)
      sent(conn, GenServer.call(model, {:next, JSON.decode!(body)}))
    end

    defp sent(conn, {:status, status}), do: sent(conn, {:status, status, "Failed."})

    defp sent(conn, {:status, status, message}) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, JSON.encode!(%{error: %{message: message}}))
    end

    defp sent(conn, %ReqLLM.Response{} = response) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      events =
        response
        |> chunks()
        |> Enum.map(&["data: ", JSON.encode!(&1), "\n\n"])

      {:ok, conn} = chunk(conn, [events, "data: [DONE]\n\n"])
      conn
    end

    defp chunks(response) do
      calls = ReqLLM.Response.tool_calls(response)
      usage = response.usage || %{}

      texts(response) ++
        [
          %{choices: [%{index: 0, delta: %{tool_calls: Enum.with_index(calls, &tool_call/2)}}]},
          %{
            choices: [
              %{
                index: 0,
                delta: %{},
                finish_reason: if(calls == [], do: "stop", else: "tool_calls")
              }
            ]
          },
          %{
            choices: [],
            usage: %{
              prompt_tokens: Map.get(usage, :input_tokens, 0),
              completion_tokens: Map.get(usage, :output_tokens, 0)
            }
          }
        ]
    end

    defp texts(%ReqLLM.Response{message: %{content: content}}) do
      for %{type: :text, text: text} <- content,
          do: %{choices: [%{index: 0, delta: %{role: "assistant", content: text}}]}
    end

    defp tool_call(%ReqLLM.ToolCall{id: id, function: function}, index),
      do: %{
        index: index,
        id: id,
        type: "function",
        function: Map.take(function, [:name, :arguments])
      }
  end
end
