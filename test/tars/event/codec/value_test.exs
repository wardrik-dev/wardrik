defmodule Tars.Event.Codec.ValueTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message.ContentPart
  alias Tars.Event.Codec.Value

  defp parts(content), do: Value.message(%ReqLLM.Message{role: :user, content: content})["parts"]

  describe "message parts" do
    test "take OpenTelemetry's type for each kind of content" do
      assert parts([
               ContentPart.text("hi"),
               ContentPart.thinking("hmm"),
               ContentPart.image_url("https://example.com/a.png"),
               ContentPart.video_url("https://example.com/a.mp4"),
               ContentPart.image(<<1, 2>>, "image/png"),
               %ContentPart{type: :file, data: "%PDF", media_type: "application/pdf"},
               %ContentPart{type: :file, file_id: "file_1", media_type: "application/pdf"}
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

    test "take plain text for a message holding a string" do
      assert parts("hello") == [%{"type" => "text", "content" => "hello"}]
    end

    test "cut text too long to keep, whole characters only, and say so" do
      [part] = parts(String.duplicate("é", 40_000))

      assert part["truncated"] == true
      assert byte_size(part["content"]) <= 64 * 1024
      assert String.valid?(part["content"])
    end
  end

  test "a message keeps its author's name" do
    assert %{"name" => "jon"} =
             Value.message(%ReqLLM.Message{role: :user, content: "hi", name: "jon"})
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

  test "usage names reasoning tokens and cost as OpenTelemetry's conventions do" do
    assert Value.usage(%{input_tokens: 1, reasoning_tokens: 2, total_cost: 0.1}) ==
             %{"input_tokens" => 1, "reasoning" => %{"output_tokens" => 2}, "cost_usd" => 0.1}
  end
end
