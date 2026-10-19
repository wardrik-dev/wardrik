defmodule Wardrik.LLM.ReqLLMTest do
  use ExUnit.Case, async: true
  use Mimic

  alias ReqLLM.Context
  alias ReqLLM.Error.API
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.Blob
  alias Wardrik.Conversation.Reasoning
  alias Wardrik.Conversation.ServerToolCall
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Conversation.ToolError
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Conversation.Uri
  alias Wardrik.Conversation.User
  alias Wardrik.LLM.Answer
  alias Wardrik.LLM.Client
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Error
  alias Wardrik.LLM.Model
  alias Wardrik.LLM.ReqLLM.Convert
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Usage

  @client %Wardrik.LLM.ReqLLM{}

  setup :verify_on_exit!

  # An assistant message carrying everything a provider attaches to one:
  # signed and redacted reasoning, its reasoning details, its own metadata,
  # media with metadata of their own, and calls it asked for, ran itself, or
  # wrote arguments for that do not read as JSON.
  defp provided do
    asked =
      "call_1"
      |> ReqLLM.ToolCall.new("deploy", ~s({"repo":"wardrik"}))
      |> ReqLLM.ToolCall.put_metadata(%{thought_signature: "ts-1"})

    %ReqLLM.Message{
      role: :assistant,
      content: [
        ContentPart.thinking("Check the build.", %{signature: "sig-1"}),
        ContentPart.thinking("", %{redacted: true, data: "opaque"}),
        ContentPart.text("Deploying.", %{"annotations" => [%{"type" => "url_citation"}]}),
        ContentPart.file(<<1, 2>>, "plan.pdf", "application/pdf", %{prompt_cache_breakpoint: "a"})
      ],
      tool_calls: [
        asked,
        ReqLLM.ToolCall.new_builtin("ws_1", "web_search", ~s({"query":"otp"})),
        ReqLLM.ToolCall.new("call_2", "deploy", ~s({"repo": ))
      ],
      metadata: %{response_id: "resp_9", phase: "final_answer", phase_items: [{:kept, "as is"}]},
      reasoning_details: [
        %ReasoningDetails{
          text: "Check the build.",
          signature: "sig-1",
          encrypted?: true,
          provider: :anthropic,
          format: "anthropic-thinking-v1",
          provider_data: %{"type" => "thinking"}
        }
      ]
    }
  end

  defp conversation do
    Context.new([
      Context.user("Ship it."),
      %ReqLLM.Message{
        role: :user,
        content: [
          ContentPart.image_url("https://example.com/a.png"),
          ContentPart.video_url("https://example.com/a.mp4"),
          ContentPart.image(<<1, 2>>, "image/png"),
          %ContentPart{type: :file, data: "%PDF", media_type: "application/pdf"},
          ContentPart.file_id("file_1", "application/pdf")
        ]
      },
      provided(),
      Context.tool_result_message("deploy", "call_1", "done"),
      Context.tool_result_message("deploy", "call_2", ~s({"error":"unreadable"}), %{
        is_error: true
      }),
      Context.assistant("Shipped.")
    ])
  end

  # Every atom `term` holds, its structs' names and fields among them.
  defp atoms(term) when is_atom(term), do: [term]
  defp atoms(term) when is_list(term), do: Enum.flat_map(term, &atoms/1)
  defp atoms(term) when is_tuple(term), do: term |> Tuple.to_list() |> atoms()
  defp atoms(%_{} = term), do: term |> Map.to_list() |> atoms()
  defp atoms(term) when is_map(term), do: term |> Map.to_list() |> atoms()
  defp atoms(_term), do: []

  describe "a conversation" do
    test "goes to ReqLLM and back losing nothing" do
      context = conversation()
      assert context |> Convert.from_req_llm() |> Convert.to_req_llm() == context
    end

    test "comes back as Wardrik's own values, with what only ReqLLM reads kept aside" do
      assert %Conversation{messages: [said, shown, %Assistant{} = asked, done, failed, shipped]} =
               Convert.from_req_llm(conversation())

      assert said == User.new("Ship it.")

      assert shown.parts == [
               %Uri{modality: "image", uri: "https://example.com/a.png"},
               %Uri{modality: "video", uri: "https://example.com/a.mp4"},
               %Blob{modality: "image", data: <<1, 2>>, mime_type: "image/png"},
               %Blob{modality: "document", data: "%PDF", mime_type: "application/pdf"},
               %Wardrik.Conversation.File{file_id: "file_1", mime_type: "application/pdf"}
             ]

      assert [
               %Reasoning{text: "Check the build."},
               %Reasoning{text: ""},
               %Text{text: "Deploying."},
               %Blob{modality: "document", data: <<1, 2>>},
               %ToolCall{id: "call_1", name: "deploy", arguments: %{"repo" => "wardrik"}},
               %ServerToolCall{id: "ws_1", name: "web_search", arguments: %{"query" => "otp"}},
               %ToolCall{id: "call_2", name: "deploy", arguments: ~s({"repo": )}
             ] = asked.parts

      assert Assistant.calls(asked) |> Enum.map(& &1.id) == ["call_1", "call_2"]
      assert %ToolResult{call_id: "call_1", name: "deploy", parts: [%Text{text: "done"}]} = done
      assert %ToolError{call_id: "call_2", name: "deploy"} = failed
      assert shipped == Assistant.new("Shipped.")
    end

    test "keeps no ReqLLM atom aside, so what an agent stores reads back without ReqLLM" do
      kept = atoms(Convert.from_req_llm(conversation()))

      refute Enum.any?(kept, &String.starts_with?(Atom.to_string(&1), "Elixir.ReqLLM"))
      refute Enum.any?([:thought_signature, :phase_items, :anthropic, :encrypted?], &(&1 in kept))
    end
  end

  describe "an answer" do
    test "is the response's message, usage, finish reason, model, id and object" do
      response = %ReqLLM.Response{
        id: "resp_1",
        model: "claude-sonnet-5",
        context: Context.new(),
        message: provided(),
        usage: %{input_tokens: 12, output_tokens: 4, cached_tokens: 3, total_cost: 0.01},
        finish_reason: :tool_calls,
        object: %{"q0" => %{"probability" => 0.4}}
      }

      assert %Answer{
               message: %Assistant{} = message,
               usage: %Usage{
                 input_tokens: 12,
                 output_tokens: 4,
                 cached_tokens: 3,
                 total_cost: 0.01
               },
               finish_reason: :tool_calls,
               model: "claude-sonnet-5",
               id: "resp_1",
               object: %{"q0" => %{"probability" => 0.4}}
             } = Convert.answer(response)

      assert message == Convert.from_req_llm(provided())
    end

    test "with no message says nothing, and with no usage used nothing it reported" do
      response = %ReqLLM.Response{
        id: "r",
        model: "m",
        context: Context.new(),
        finish_reason: "stop"
      }

      assert %Answer{message: %Assistant{parts: []}, usage: nil, finish_reason: :stop} =
               Convert.answer(response)
    end

    test "that ReqLLM read as a JSON object is its text" do
      message = %ReqLLM.Message{
        role: :assistant,
        content: [%{type: :object, object: %{"a" => 1}}]
      }

      assert %Assistant{parts: [%Text{text: ~s({"a":1})}]} = Convert.from_req_llm(message)
    end
  end

  describe "an error" do
    test "carries the status the provider answered with, and how long it asked to be left" do
      limited =
        API.Request.exception(status: 429, reason: "slow", headers: [{"Retry-After", "3"}])

      assert Convert.error(limited) ==
               %Error{status: 429, retry_after: 3, message: "API request failed (429): slow"}

      busy = API.Request.exception(status: 503, headers: %{"retry-after" => ["120"]})
      assert %Error{status: 503, retry_after: 120} = Convert.error(busy)

      dated = API.Request.exception(status: 503, headers: [{"retry-after", "Wed, 21 Oct"}])
      assert %Error{status: 503, retry_after: nil} = Convert.error(dated)
    end

    test "of a stream that broke is the error beneath it, where it wraps one" do
      refused = API.Request.exception(status: 402, reason: "Insufficient balance")

      assert Convert.error(%API.Stream{reason: "Stream failed", cause: refused}) ==
               %Error{status: 402, message: "API request failed (402): Insufficient balance"}

      assert Convert.error(%API.Stream{reason: "Stream failed: closed"}) ==
               %Error{message: "Stream failed: closed"}
    end

    test "with no answer from the provider has no status" do
      assert Convert.error(%Mint.TransportError{reason: :closed}) ==
               %Error{message: "socket closed"}

      assert Convert.error(:timeout) == %Error{message: ":timeout"}
    end
  end

  test "a tool's parameters are shown to a model as JSON Schema" do
    assert %{"type" => "object", "required" => ["value"], "properties" => %{"value" => _value}} =
             Wardrik.LLM.Tools.schema(Wardrik.Test.EchoTool.tool())
  end

  describe "as the host's client" do
    defp request(opts \\ []) do
      config = Config.new([model_spec: "anthropic:claude-sonnet-5"] ++ opts)
      Request.new(config, Conversation.new([User.new("Ship it.")]))
    end

    test "streams each piece of the answer, then answers with it" do
      test_pid = self()
      call = ReqLLM.StreamChunk.tool_call("deploy", %{}, %{id: "call_1"})

      expect(ReqLLM, :stream_text, fn "anthropic:claude-sonnet-5", %Context{} = context, opts ->
        send(test_pid, {:asked, context, opts})
        {:ok, :streamed}
      end)

      expect(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
        opts[:on_thinking].("hmm")
        opts[:on_result].("Shipped.")
        opts[:on_tool_call].(call)
        {:ok, %ReqLLM.Response{id: "r", model: "m", context: Context.new(), message: provided()}}
      end)

      request = request(tools: [Wardrik.Test.EchoTool], system: "Be brief.")

      assert {:ok, %Answer{message: %Assistant{}}} =
               Client.stream(@client, request, &send(test_pid, {:delta, &1}))

      assert_received {:asked, context, opts}
      assert context.messages == [Context.user("Ship it.")]
      assert opts[:system_prompt] == "Be brief."
      assert [%ReqLLM.Tool{name: "echo"}] = opts[:tools]

      assert_received {:delta, {:reasoning, "hmm"}}
      assert_received {:delta, {:text, "Shipped."}}
      assert_received {:delta, {:tool_call, %ToolCall{id: "call_1", name: "deploy"}}}
    end

    test "fails with the error, whether the stream never began or broke" do
      stub(ReqLLM, :stream_text, fn _model, _context, _opts ->
        {:error, API.Request.exception(status: 401, reason: "Invalid key")}
      end)

      assert {:error, %Error{status: 401}} =
               Client.stream(@client, request(), fn _delta -> :ok end)

      stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

      stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, _opts ->
        {:error, %API.Stream{reason: "Stream failed: closed"}}
      end)

      assert {:error, %Error{status: nil, message: "Stream failed: closed"}} =
               Client.stream(@client, request(), fn _delta -> :ok end)
    end

    test "lets a throw from what it hands each piece through" do
      stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:ok, :streamed} end)

      stub(ReqLLM.StreamResponse, :process_stream, fn :streamed, opts ->
        opts[:on_result].("Half")
        {:ok, %ReqLLM.Response{id: "r", model: "m", context: Context.new()}}
      end)

      assert catch_throw(Client.stream(@client, request(), fn _delta -> throw(:interrupt) end)) ==
               :interrupt
    end

    test "generates an answer whole" do
      expect(ReqLLM, :generate_text, fn "anthropic:claude-sonnet-5", %Context{}, _opts ->
        {:ok, %ReqLLM.Response{id: "r", model: "m", context: Context.new(), message: provided()}}
      end)

      assert {:ok, %Answer{id: "r"}} = Client.generate(@client, request())
    end

    test "evaluates a state, with only the options an evaluation takes" do
      questions = %{"q0" => %{type: :boolean, instructions: "Is it urgent?"}}
      request = Request.put_opts(request(), api_key: "sk-evaluating")

      expect(ReqLLM, :evaluate, fn "anthropic:claude-sonnet-5",
                                   %{"tool" => "deploy"},
                                   ^questions,
                                   opts ->
        assert opts == [api_key: "sk-evaluating"]
        object = %{"q0" => %{"type" => "boolean", "probability" => 0.9}}
        {:ok, %ReqLLM.Response{id: "e", model: "jev", context: Context.new(), object: object}}
      end)

      assert {:ok, %Answer{object: %{"q0" => %{"probability" => 0.9}}}} =
               Client.evaluate(@client, request,
                 state: %{"tool" => "deploy"},
                 questions: questions
               )
    end

    test "knows a model's window from the catalog, and the secret its key is read from" do
      assert {:ok, %Model{window: 1_000_000}} = Client.model(@client, "anthropic:claude-sonnet-5")
      assert {:ok, %Model{key: "XAI_API_KEY"}} = Client.model(@client, "xai:grok-4")
      assert {:ok, %Model{key: nil}} = Client.model(@client, "zai:glm-4.6")
      assert {:error, _unknown} = Client.model(@client, "nowhere:no-such-model")
    end

    test "prices tokens at the catalog's prices, and a model it does not know at nothing" do
      usage = %Usage{input_tokens: 10_000, output_tokens: 2_000}

      assert price = Client.price(@client, "anthropic:claude-sonnet-5", usage)
      assert is_float(price) and price > 0
      assert Client.price(@client, "nowhere:no-such-model", usage) == nil
    end
  end
end
