defmodule Wardrik.Testing.ModelTest do
  use ExUnit.Case, async: true

  alias Wardrik.Testing.Model

  defp ask(model) do
    endpoint = Model.endpoint(model)

    with {:ok, stream} <-
           ReqLLM.stream_text(endpoint[:model], "Hi.",
             base_url: endpoint[:base_url],
             api_key: "none",
             retry: false
           ),
         do: ReqLLM.StreamResponse.process_stream(stream, on_chunk: fn _chunk -> :ok end)
  end

  test "answers each call with the next answer, as text or tool calls" do
    answers = [Model.text("Hello."), Model.calls([{"c1", "echo", %{"text" => "x"}}])]
    model = start_supervised!({Model, answers})

    assert {:ok, first} = ask(model)
    assert ReqLLM.Response.text(first) == "Hello."

    assert {:ok, second} = ask(model)
    assert [%ReqLLM.ToolCall{id: "c1"}] = ReqLLM.Response.tool_calls(second)
  end

  test "answers with a function of the request, or fails with a status" do
    test = self()

    answer = fn request ->
      send(test, {:asked, request["messages"]})
      {:status, 503}
    end

    model = start_supervised!({Model, answer})

    assert {:error, _reason} = ask(model)
    assert_received {:asked, [%{"role" => "user", "content" => "Hi."}]}
  end
end
