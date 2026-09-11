defmodule Tars.LLM.ToolRunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Tars.Event
  alias Tars.LLM.Config
  alias Tars.LLM.ToolRunner
  alias Tars.Scope

  setup do
    agent_id = make_ref()
    :ok = Event.Bus.subscribe(agent_id)
    {:ok, agent_id: agent_id}
  end

  defp tool!(name, callback) do
    ReqLLM.Tool.new!(name: name, description: "test tool", callback: callback)
  end

  defp scope(agent_id, tools) do
    Config.new(tools: tools) |> Scope.root(agent_id, name: "turn")
  end

  # The shape `ReqLLM.Response.classify/1` actually produces: `:arguments`,
  # already decoded, with string ids.
  defp call(id, name, arguments), do: %{id: id, name: name, arguments: arguments}

  describe "execute_many_async/2" do
    test "executes multiple known tools and publishes progress", %{agent_id: agent_id} do
      tools = [
        tool!("echo", fn input -> {:ok, input} end),
        tool!("reverse", fn %{"input" => input} -> {:ok, String.reverse(input)} end)
      ]

      calls = [
        call("call_1", "echo", %{"input" => "Hello"}),
        call("call_2", "reverse", %{"input" => "World"})
      ]

      messages = ToolRunner.execute_many_async(calls, scope(agent_id, tools))

      assert_receive %Event{payload: {:tool_started, "call_1", "echo"}}

      assert_receive %Event{
        payload: {:tool_finished, "call_1", "echo", {:ok, %{"input" => "Hello"}}}
      }

      assert_receive %Event{payload: {:tool_started, "call_2", "reverse"}}
      assert_receive %Event{payload: {:tool_finished, "call_2", "reverse", {:ok, "dlroW"}}}

      assert Enum.map(messages, & &1.tool_call_id) == ["call_1", "call_2"]
      assert Enum.map(messages, & &1.name) == ["echo", "reverse"]
      assert Enum.all?(messages, &(&1.role == :tool))
    end

    test "answers an unknown tool with an error result rather than raising", %{
      agent_id: agent_id
    } do
      calls = [call("call_1", "nope", %{})]

      assert [message] = ToolRunner.execute_many_async(calls, scope(agent_id, []))

      assert_receive %Event{
        payload: {:tool_finished, "call_1", "nope", {:error, "Unknown tool: nope"}}
      }

      assert message.tool_call_id == "call_1"
      assert message.metadata.is_error
    end

    test "a crashing tool is isolated and still yields a paired result", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _ -> exit(:kaboom) end)]
      calls = [call("call_1", "boom", %{})]

      {[message], _log} =
        with_log(fn -> ToolRunner.execute_many_async(calls, scope(agent_id, tools)) end)

      assert message.tool_call_id == "call_1"
      assert message.name == "boom"
      assert message.metadata.is_error
    end

    test "a non-string error reason is inspected into the result", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _ -> {:error, %RuntimeError{message: "nope"}} end)]

      assert [message] =
               ToolRunner.execute_many_async(
                 [call("call_1", "boom", %{})],
                 scope(agent_id, tools)
               )

      assert message.tool_call_id == "call_1"
      assert message.metadata.is_error
    end

    test "results come back in call order even when tools finish out of order", %{
      agent_id: agent_id
    } do
      test_pid = self()

      tools = [
        tool!("waiter", fn _ ->
          send(test_pid, {:waiting, self()})
          receive do: (:go -> {:ok, "waiter"})
        end),
        tool!("runner", fn _ ->
          send(test_pid, :runner_done)
          {:ok, "runner"}
        end)
      ]

      calls = [call("call_1", "waiter", %{}), call("call_2", "runner", %{})]

      task = Task.async(fn -> ToolRunner.execute_many_async(calls, scope(agent_id, tools)) end)

      # call_2's tool completes first; call_1's is still blocked. Any ordering
      # by completion rather than by call would put call_2 first.
      assert_receive {:waiting, waiter}
      assert_receive :runner_done
      send(waiter, :go)

      messages = Task.await(task)

      assert Enum.map(messages, & &1.tool_call_id) == ["call_1", "call_2"]
      assert Enum.map(messages, & &1.name) == ["waiter", "runner"]
    end

    test "events reach every subscriber", %{agent_id: agent_id} do
      test_pid = self()

      spawn_link(fn ->
        Event.Bus.subscribe(agent_id)
        send(test_pid, :ready)
        receive do: (%Event{payload: {:tool_started, _, _}} = e -> send(test_pid, {:other, e}))
      end)

      assert_receive :ready
      assert [_, _] = Event.Bus.subscribers(agent_id)

      tools = [tool!("echo", fn input -> {:ok, input} end)]
      ToolRunner.execute_many_async([call("call_1", "echo", %{})], scope(agent_id, tools))

      assert_receive %Event{payload: {:tool_started, "call_1", "echo"}}
      assert_receive {:other, %Event{payload: {:tool_started, "call_1", "echo"}}}
    end
  end

  describe "spans" do
    test "each call runs on its own child span of the turn", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]

      calls = [call("call_1", "echo", %{}), call("call_2", "echo", %{})]
      turn = scope(agent_id, tools)

      ToolRunner.execute_many_async(calls, turn)

      assert_receive %Event{payload: {:tool_started, "call_1", "echo"}} = one
      assert_receive %Event{payload: {:tool_started, "call_2", "echo"}} = two

      for event <- [one, two] do
        refute Event.root?(event)
        assert event.source.trace.trace_id == turn.source.trace.trace_id
        assert event.source.trace.parent_span_id == turn.source.trace.span_id
        assert event.source.trace.name == "echo"
      end

      assert one.source.trace.span_id != two.source.trace.span_id
    end

    test "a call's start and finish share one span", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]

      ToolRunner.execute(call("call_1", "echo", %{}), scope(agent_id, tools))

      assert_receive %Event{payload: {:tool_started, "call_1", "echo"}} = started
      assert_receive %Event{payload: {:tool_finished, "call_1", "echo", _}} = finished

      assert started.source.trace.span_id == finished.source.trace.span_id
    end

    test "a call announces both ends of its span", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]
      turn = scope(agent_id, tools)

      ToolRunner.execute(call("call_1", "echo", %{}), turn)

      assert_receive %Event{payload: {:span_started, "echo"}} = started
      assert_receive %Event{payload: {:span_finished, :ok, _ms}} = finished

      assert started.source.trace.span_id == finished.source.trace.span_id
      assert started.source.trace.parent_span_id == turn.source.trace.span_id
    end

    test "a failing tool closes its span as a failure", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _input -> {:error, :nope} end)]

      ToolRunner.execute(call("call_1", "boom", %{}), scope(agent_id, tools))

      assert_receive %Event{payload: {:span_finished, {:error, :nope}, _ms}}
    end

    test "a crashing call still closes its span", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _input -> exit(:kaboom) end)]

      with_log(fn ->
        ToolRunner.execute_many_async([call("call_1", "boom", %{})], scope(agent_id, tools))
      end)

      assert_receive %Event{payload: {:span_started, "boom"}} = started
      assert_receive %Event{payload: {:span_finished, {:error, :kaboom}, _ms}} = finished

      assert started.source.trace.span_id == finished.source.trace.span_id
    end
  end

  describe "execute/2" do
    test "returns a canonical tool-result message", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]

      message = ToolRunner.execute(call("call_1", "echo", %{"a" => 1}), scope(agent_id, tools))

      assert_receive %Event{payload: {:tool_started, "call_1", "echo"}}
      assert_receive %Event{payload: {:tool_finished, "call_1", "echo", {:ok, %{"a" => 1}}}}
      assert message.role == :tool
      assert message.tool_call_id == "call_1"
      assert message.name == "echo"
    end
  end
end
