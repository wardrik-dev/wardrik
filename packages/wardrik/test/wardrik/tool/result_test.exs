defmodule Wardrik.Tool.ResultTest do
  use ExUnit.Case, async: true

  alias Wardrik.Tool.Result

  test "ok/1 marks a successful call" do
    assert Result.ok(%{"count" => 1}) == {:ok, %{"ok" => true, "result" => %{"count" => 1}}}
  end

  test "a failed call is a successful result saying so" do
    assert {:ok, %{"ok" => false}} = Result.error(:brave_rate_limited)
  end

  test "an atom reason keeps its own name and reads as a sentence" do
    assert {:ok, %{"error" => error}} = Result.error(:missing_brave_api_key)

    assert error == %{"code" => "missing_brave_api_key", "message" => "missing brave api key"}
  end

  test "a string reason is reported verbatim under a generic code" do
    assert {:ok, %{"error" => error}} = Result.error("upstream said no")

    assert error == %{"code" => "request_failed", "message" => "upstream said no"}
  end

  test "a tagged reason keeps the tag as the code and describes the detail" do
    assert {:ok, %{"error" => error}} = Result.error({:invalid_slug, "GMAIL_NOPE"})

    assert error["code"] == "invalid_slug"
    assert error["message"] =~ "invalid slug"
    assert error["message"] =~ "GMAIL_NOPE"
  end

  test "anything else is inspected rather than lost" do
    assert {:ok, %{"error" => %{"code" => "request_failed", "message" => message}}} =
             Result.error(%RuntimeError{message: "nope"})

    assert message =~ "nope"
  end

  test "error/2 takes a code and sentence chosen by the caller" do
    assert Result.error(:no_key, "Set BRAVE_API_KEY.") ==
             {:ok,
              %{
                "ok" => false,
                "error" => %{"code" => "no_key", "message" => "Set BRAVE_API_KEY."}
              }}
  end
end
