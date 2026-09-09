defmodule Tars.LLM.ToolRunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Tars.Events
  alias Tars.LLM.Config
  alias Tars.LLM.ToolRunner

  setup do
    agent_id = make_ref()
    :ok = Events.subscribe(agent_id)
    {:ok, agent_id: agent_id}
  end

  defp tool!(name, callback) do
    ReqLLM.Tool.new!(name: name, description: "test tool", callback: callback)
  end

  defp config(agent_id, tools), do: Config.new(agent_id: agent_id, tools: tools)

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

      messages = ToolRunner.execute_many_async(calls, config(agent_id, tools))

      assert_receive {:tool_started, "call_1", "echo"}
      assert_receive {:tool_finished, "call_1", "echo", {:ok, %{"input" => "Hello"}}}
      assert_receive {:tool_started, "call_2", "reverse"}
      assert_receive {:tool_finished, "call_2", "reverse", {:ok, "dlroW"}}

      assert Enum.map(messages, & &1.tool_call_id) == ["call_1", "call_2"]
      assert Enum.map(messages, & &1.name) == ["echo", "reverse"]
      assert Enum.all?(messages, &(&1.role == :tool))
    end

    test "answers an unknown tool with an error result rather than raising", %{
      agent_id: agent_id
    } do
      calls = [call("call_1", "nope", %{})]

      assert [message] = ToolRunner.execute_many_async(calls, config(agent_id, []))

      assert_receive {:tool_finished, "call_1", "nope", {:error, "Unknown tool: nope"}}
      assert message.tool_call_id == "call_1"
      assert message.metadata.is_error
    end

    test "a crashing tool is isolated and still yields a paired result", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _ -> exit(:kaboom) end)]
      calls = [call("call_1", "boom", %{})]

      {[message], _log} =
        with_log(fn -> ToolRunner.execute_many_async(calls, config(agent_id, tools)) end)

      assert message.tool_call_id == "call_1"
      assert message.name == "boom"
      assert message.metadata.is_error
    end

    test "a non-string error reason is inspected into the result", %{agent_id: agent_id} do
      tools = [tool!("boom", fn _ -> {:error, %RuntimeError{message: "nope"}} end)]

      assert [message] =
               ToolRunner.execute_many_async(
                 [call("call_1", "boom", %{})],
                 config(agent_id, tools)
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

      task = Task.async(fn -> ToolRunner.execute_many_async(calls, config(agent_id, tools)) end)

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
        Events.subscribe(agent_id)
        send(test_pid, :ready)
        receive do: (event -> send(test_pid, {:other, event}))
      end)

      assert_receive :ready
      assert [_, _] = Events.subscribers(agent_id)

      tools = [tool!("echo", fn input -> {:ok, input} end)]
      ToolRunner.execute_many_async([call("call_1", "echo", %{})], config(agent_id, tools))

      assert_receive {:tool_started, "call_1", "echo"}
      assert_receive {:other, {:tool_started, "call_1", "echo"}}
    end
  end

  describe "execute/2" do
    test "returns a canonical tool-result message", %{agent_id: agent_id} do
      tools = [tool!("echo", fn input -> {:ok, input} end)]

      message = ToolRunner.execute(call("call_1", "echo", %{"a" => 1}), config(agent_id, tools))

      assert_receive {:tool_started, "call_1", "echo"}
      assert_receive {:tool_finished, "call_1", "echo", {:ok, %{"a" => 1}}}
      assert message.role == :tool
      assert message.tool_call_id == "call_1"
      assert message.name == "echo"
    end
  end
end
