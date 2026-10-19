defmodule Wardrik.Event.Codec.ValueTest do
  use ExUnit.Case, async: true

  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.Blob
  alias Wardrik.Conversation.Reasoning
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Conversation.Uri
  alias Wardrik.Event.Codec.Value

  defp parts(parts), do: Value.message(%Assistant{parts: parts})["parts"]

  describe "message parts" do
    test "take OpenTelemetry's type for each kind of content" do
      assert parts([
               %Text{text: "hi"},
               %Reasoning{text: "hmm", provider: %{"metadata" => %{"signature" => "s"}}},
               %Uri{modality: "image", uri: "https://example.com/a.png"},
               %Uri{modality: "video", uri: "https://example.com/a.mp4"},
               %Blob{modality: "image", data: <<1, 2>>, mime_type: "image/png"},
               %Blob{modality: "document", data: "%PDF", mime_type: "application/pdf"},
               %Wardrik.Conversation.File{file_id: "file_1", mime_type: "application/pdf"}
             ]) == [
               %{"type" => "text", "content" => "hi"},
               %{"type" => "reasoning", "content" => "hmm"},
               %{"type" => "uri", "modality" => "image", "uri" => "https://example.com/a.png"},
               %{"type" => "uri", "modality" => "video", "uri" => "https://example.com/a.mp4"},
               %{
                 "type" => "blob",
                 "modality" => "image",
                 "mime_type" => "image/png",
                 "content" => "AQI="
               },
               %{
                 "type" => "blob",
                 "modality" => "document",
                 "mime_type" => "application/pdf",
                 "content" => "JVBERg=="
               },
               %{
                 "type" => "file",
                 "modality" => "document",
                 "mime_type" => "application/pdf",
                 "file_id" => "file_1"
               }
             ]
    end

    test "put the calls a model asked for after what it said" do
      call = %ToolCall{id: "call_1", name: "deploy", arguments: ~s({"repo": )}

      assert parts([call, %Text{text: "Deploying."}]) == [
               %{"type" => "text", "content" => "Deploying."},
               %{
                 "type" => "tool_call",
                 "id" => "call_1",
                 "name" => "deploy",
                 "arguments" => ~s({"repo": )
               }
             ]
    end

    test "cut text too long to keep, whole characters only, and say so" do
      [part] = parts([%Text{text: String.duplicate("é", 40_000)}])

      assert part["truncated"] == true
      assert byte_size(part["content"]) <= 64 * 1024
      assert String.valid?(part["content"])
    end
  end

  test "a tool's answer is named for its tool" do
    assert %{"role" => "tool", "name" => "deploy"} =
             Value.message(%ToolResult{call_id: "c", name: "deploy", parts: [%Text{text: "ok"}]})
  end

  describe "json/1" do
    test "keeps what JSON holds and translates the rest" do
      assert Value.json(%{1 => :atom, "list" => [{:a, 1}], nested: %{ok: true, none: nil}}) == %{
               "1" => "atom",
               "list" => [["a", 1]],
               "nested" => %{"ok" => true, "none" => nil}
             }
    end

    test "shows what JSON cannot hold as inspect/1 does" do
      pid = self()

      assert Value.json(pid) == inspect(pid)
      assert Value.json(<<255>>) == inspect(<<255>>)
    end
  end

  test "a value too long to keep is cut to a preview" do
    capped = Value.capped(%{}, "result", %{"text" => String.duplicate("x", 70_000)})

    assert capped["truncated"] == true
    assert is_binary(capped["result"]["preview"])
  end

  test "an answer that is no tool result is an error" do
    assert {"error", nil, %{"type" => "invalid_result"}} = Value.result(:what)
  end

  test "no usage, and no principal, are nothing" do
    assert Value.usage(nil) == nil
    assert Value.principal(nil) == nil
  end

  test "usage names reasoning tokens as OpenTelemetry's conventions do, and leaves cost to cost" do
    usage = %Wardrik.LLM.Usage{input_tokens: 1, reasoning_tokens: 2, total_cost: 0.1}

    assert Value.usage(usage) ==
             %{"input_tokens" => 1, "reasoning" => %{"output_tokens" => 2}}
  end

  test "a cost is whole micro-dollars and what priced it" do
    assert Value.cost(%{micro_usd: 4_200, source: :catalog}) ==
             %{"micro_usd" => 4_200, "source" => "catalog"}

    assert Value.cost(nil) == nil
  end
end
