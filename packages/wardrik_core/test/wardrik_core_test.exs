defmodule WardrikCoreTest do
  use ExUnit.Case, async: true
  use Mimic

  import WardrikCore.Test.LLM

  alias WardrikCore.Context

  doctest WardrikCore

  defmodule Watch do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: step, metadata: %{test: pid}} = context, next, _opts) do
      send(pid, {:step, step})
      next.(%{context | on_chunk: [(&send(pid, {:chunk, &1})) | context.on_chunk]})
    end
  end

  describe "child_spec/1" do
    test "loads every module a saved agent may name before agents start" do
      for app <- [:wardrik_core, :req_llm], module <- Application.spec(app, :modules) do
        assert :code.is_loaded(module), "#{inspect(module)} isn't loaded"
      end
    end
  end

  describe "generate/1" do
    test "calls the model through the middleware, streaming nothing, and measures it" do
      stub(ReqLLM.StreamResponse, :process_stream, fn response, opts ->
        opts[:on_chunk].(ReqLLM.StreamChunk.text("A summary."))
        {:ok, response}
      end)

      response = %{answer("A summary.") | usage: %{input_tokens: 30, output_tokens: 5}}

      expect(ReqLLM, :stream_text, fn "anthropic:claude-haiku-4-5",
                                      [system, _user],
                                      [tools: [], receive_timeout: _, stream_idle_timeout: _] ->
        assert %{role: :system} = system
        {:ok, response}
      end)

      context =
        Context.new(
          model: "anthropic:claude-haiku-4-5",
          instructions: "Summarise.",
          messages: [ReqLLM.Context.user("hi")],
          middleware: [Watch],
          metadata: %{test: self()}
        )

      assert {:ok, generated} = WardrikCore.generate(context)
      assert ReqLLM.Response.text(generated.response) == "A summary."
      assert [_user, %{role: :assistant}] = generated.messages
      assert %{input_tokens: 30, output_tokens: 5} = generated.measurements
      assert generated.step == nil
      assert_receive {:step, :generate}
      refute_received {:chunk, _chunk}
    end
  end

  describe "context_window/1" do
    test "gives what the catalog says a model reads, or nil" do
      assert WardrikCore.context_window("anthropic:claude-haiku-4-5") == 200_000
      assert WardrikCore.context_window("nope:nope") == nil
    end
  end

  describe "price/1" do
    test "gives what the catalog says a model costs in dollars, or nil" do
      assert WardrikCore.price("anthropic:claude-haiku-4-5") == [
               input: 1.0,
               output: 5.0,
               cache_read: 0.1,
               cache_write: 1.25
             ]

      assert WardrikCore.price("nope:nope") == nil
    end
  end

  describe "evaluate/2" do
    test "gives each answer under its question's name, and what the call used" do
      questions = %{"urgent" => %{type: :boolean, instructions: "Is this urgent?"}}

      expect(ReqLLM, :evaluate, fn "anthropic:claude-haiku-4-5",
                                   "The site is down.",
                                   ^questions,
                                   [receive_timeout: _, stream_idle_timeout: _] ->
        {:ok,
         %ReqLLM.Response{
           id: "eval",
           model: "claude-haiku-4-5",
           context: nil,
           message: nil,
           object: %{"urgent" => %{"probability" => 0.9}},
           usage: %{input_tokens: 12, output_tokens: 1, total_cost: 0.001}
         }}
      end)

      assert {:ok, %{"urgent" => %{"probability" => 0.9}},
              %{input_tokens: 12, output_tokens: 1, usd: 0.001}} =
               WardrikCore.evaluate(WardrikCore.Context.new([]),
                 model: "anthropic:claude-haiku-4-5",
                 state: "The site is down.",
                 questions: questions
               )
    end

    test "passes on why the model couldn't answer" do
      expect(ReqLLM, :evaluate, fn _model, _state, _questions, _opts -> {:error, :timeout} end)

      assert {:error, :timeout} =
               WardrikCore.evaluate(WardrikCore.Context.new([]),
                 model: "typesafe:jev-latest",
                 state: "x",
                 questions: %{}
               )
    end
  end
end
