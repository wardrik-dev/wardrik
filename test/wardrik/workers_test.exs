defmodule Wardrik.WorkersTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias WardrikCore.Context

  setup :set_mimic_global
  setup :start_wardrik

  setup %{wardrik: wardrik} do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{scope: owner(wardrik)}
  end

  @lookup %{
    "name" => "lookup",
    "description" => "Looks an order up.",
    "inputSchema" => %{"type" => "object", "properties" => %{"order" => %{"type" => "string"}}},
    "annotations" => %{"readOnlyHint" => true}
  }

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  defp worker(wardrik, id, resources, tools, answer \\ fn _call -> nil end) do
    test = self()
    scope = Wardrik.as(wardrik, id, roles: [:worker], resources: resources)

    worker =
      spawn_link(fn ->
        :ok = Wardrik.Workers.offer(scope, tools)
        send(test, {:offered, self()})
        serve(test, answer)
      end)

    assert_receive {:offered, ^worker}
    worker
  end

  defp serve(test, answer) do
    receive do
      {Wardrik.Workers, :call, call, name, arguments, meta} = message ->
        send(test, {:called, name, arguments, meta})
        respond(test, call, answer.(message))
        serve(test, answer)
    end
  end

  defp respond(test, _call, :gone) do
    Process.unlink(test)
    exit(:gone)
  end

  defp respond(_test, _call, nil), do: :ok
  defp respond(_test, call, response), do: Wardrik.Workers.answer(call, response)

  defp tools(wardrik, id) do
    tools = Wardrik.Workers.tools(%Context{agent_id: id}, wardrik: wardrik.name)
    Enum.map(tools, fn tool -> tool.name end)
  end

  test "offers an agent the tools of the workers that may serve it", %{wardrik: wardrik} do
    worker(wardrik, "acme/@shop", ["acme/agent/*"], [@lookup, %{"name" => "no spaces allowed"}])

    assert tools(wardrik, "acme/triage") == ["workers__lookup"]
    assert tools(wardrik, "rivals/triage") == []
  end

  test "leaves out what doesn't read as an MCP tool", %{wardrik: wardrik} do
    listed = [
      %{"name" => "plain"},
      %{"name" => "odd", "description" => 42, "title" => ["x"], "annotations" => "yes"},
      %{"name" => "bad_schema", "inputSchema" => %{"type" => "object", "properties" => 1}},
      %{"name" => "not_object", "inputSchema" => "string"},
      %{"description" => "nameless"},
      "a tool"
    ]

    worker(wardrik, "acme/@shop", ["acme/agent/*"], listed)

    assert Enum.sort(tools(wardrik, "acme/triage")) == ["workers__odd", "workers__plain"]

    worker(wardrik, "acme/@other", ["acme/agent/*"], %{"not" => "a list"})
    assert Enum.sort(tools(wardrik, "acme/triage")) == ["workers__odd", "workers__plain"]
  end

  test "reads whatever a worker answers without failing", %{wardrik: wardrik} do
    answers = [
      %{"result" => %{"content" => "not a list"}},
      %{
        "result" => %{"content" => [1, %{"type" => "text", "text" => %{}}, %{"type" => "image"}]}
      },
      %{"result" => "not a map"},
      %{"error" => %{"message" => 42}},
      [1, 2]
    ]

    {:ok, queue} = Agent.start_link(fn -> answers end)
    next = fn _call -> Agent.get_and_update(queue, fn [answer | rest] -> {answer, rest} end) end
    worker(wardrik, "acme/@shop", ["acme/agent/*"], [@lookup], next)

    [tool] = Wardrik.Workers.tools(%Context{agent_id: "acme/triage"}, wardrik: wardrik.name)
    context = %Context{agent_id: "acme/triage", step: {:tool_call, %{id: "call_1"}}}

    assert {:ok, "", _context} = tool.run.(%{}, context)

    assert {:ok, text, _context} = tool.run.(%{}, context)
    assert text =~ "isn't shown here"

    assert {:error, "The worker answered with neither" <> _} = tool.run.(%{}, context)
    assert {:error, "The worker answered with neither" <> _} = tool.run.(%{}, context)
    assert {:error, "The worker answered with neither" <> _} = tool.run.(%{}, context)
  end

  test "gives a tool to the principal whose worker offered it first", %{wardrik: wardrik} do
    worker(wardrik, "acme/@shop", ["acme/agent/*"], [@lookup])
    worker(wardrik, "acme/@other", ["acme/agent/*"], [%{@lookup | "description" => "Mine."}])

    [tool] = Wardrik.Workers.tools(%Context{agent_id: "acme/triage"}, wardrik: wardrik.name)
    assert tool.description =~ "Looks an order up."
    assert WardrikCore.Tool.annotation(tool, :read_only)
    refute WardrikCore.Tool.annotation(tool, :gated)
    assert WardrikCore.Tool.annotation(tool, :labels) == ["outside"]
  end

  test "gates a tool unless it's read-only, and trusts what workers say only where told to", %{
    wardrik: wardrik
  } do
    changing = %{@lookup | "annotations" => %{}}
    worker(wardrik, "acme/@shop", ["acme/agent/*"], [changing])

    [tool] = Wardrik.Workers.tools(%Context{agent_id: "acme/triage"}, wardrik: wardrik.name)
    assert WardrikCore.Tool.annotation(tool, :gated)

    trusting = %{Wardrik.Instance.fetch!(wardrik.name) | trusted_workers: true}
    [tool] = Wardrik.Workers.tools(%Context{agent_id: "acme/triage"}, wardrik: trusting)
    assert WardrikCore.Tool.annotation(tool, :labels) == []
  end

  test "runs a call on a worker, and tells the model what it answered", %{
    wardrik: wardrik,
    scope: scope
  } do
    worker(wardrik, "acme/@shop", ["acme/agent/*"], [@lookup], fn _call ->
      %{
        "result" => %{
          "content" => [%{"type" => "text", "text" => "Shipped."}],
          "_meta" => %{"costUsd" => 0.01}
        }
      }
    end)

    answers([
      calling([call("call_1", "workers__lookup", %{"order" => "A1"})]),
      answer("It shipped.")
    ])

    {:ok, agent} =
      Wardrik.Agent.define(scope, "acme/triage",
        model: "anthropic:claude-haiku-4-5",
        tools: ["workers/*"]
      )

    {:ok, _message} = Wardrik.Agent.ask(scope, agent, "Where's A1?")

    assert_receive {:called, "lookup", %{"order" => "A1"}, meta}

    assert %{"agent" => %{"key" => "acme/triage", "org" => "acme"}, "idempotencyKey" => "call_1"} =
             meta

    assert meta["run"] =~ ~r/^[0-9a-f]{32}$/

    assert %{"data" => %{"status" => "ok"}} = until("wardrik.tool_call.completed")
    until("wardrik.run.completed")
  end

  test "answers an error where the worker refuses, or goes away", %{wardrik: wardrik} do
    refusing =
      worker(wardrik, "acme/@shop", ["acme/agent/*"], [@lookup], fn _call ->
        %{"result" => %{"isError" => true, "content" => [%{"type" => "text", "text" => "No."}]}}
      end)

    [tool] = Wardrik.Workers.tools(%Context{agent_id: "acme/triage"}, wardrik: wardrik.name)
    context = %Context{agent_id: "acme/triage", step: {:tool_call, %{id: "call_1"}}}

    assert {:error, "No.", %Context{}} = tool.run.(%{}, context)

    Process.unlink(refusing)
    Process.exit(refusing, :kill)

    assert_raise Wardrik.Workers.Unavailable,
                 "No worker offers lookup now, so it didn't run.",
                 fn ->
                   tool.run.(%{}, context)
                 end
  end

  @shipped %{"result" => %{"content" => [%{"type" => "text", "text" => "Shipped."}]}}

  defp define(scope, id) do
    {:ok, agent} =
      Wardrik.Agent.define(scope, id,
        model: "anthropic:claude-haiku-4-5",
        tools: ["workers/*"],
        retries: %{"max_wait" => 1}
      )

    agent
  end

  test "runs a call again where its worker went away, where every worker may run it twice", %{
    wardrik: wardrik,
    scope: scope
  } do
    first = worker(wardrik, "acme/@shop", ["acme/agent/*"], [@lookup], fn _call -> :gone end)

    answers([
      calling([call("call_1", "workers__lookup", %{"order" => "A1"})]),
      answer("Shipped.")
    ])

    agent = define(scope, "acme/retried")
    ref = Process.monitor(first)
    {:ok, _message} = Wardrik.Agent.ask(scope, agent, "Where's A1?")

    assert_receive {:called, "lookup", _arguments, %{"idempotencyKey" => "call_1"}}
    assert_receive {:DOWN, ^ref, :process, ^first, :gone}
    worker(wardrik, "acme/@shop", ["acme/agent/*"], [@lookup], fn _call -> @shipped end)

    assert %{"data" => %{"status" => "error"}} = until("wardrik.tool_call.completed")
    until("wardrik.tool_call.retrying")

    assert_receive {:called, "lookup", _arguments, %{"idempotencyKey" => "call_1"}}, 10_000
    assert %{"data" => %{"status" => "ok"}} = until_completed()
  end

  test "waits on a person where a call that may not run twice was lost, and runs it again once approved",
       %{wardrik: wardrik, scope: scope} do
    changing = %{@lookup | "annotations" => %{}}
    first = worker(wardrik, "acme/@shop", ["acme/agent/*"], [changing], fn _call -> :gone end)

    answers([
      calling([call("call_1", "workers__lookup", %{"order" => "A1"})]),
      answer("Shipped.")
    ])

    agent = define(scope, "acme/doubtful")
    {:ok, _message} = Wardrik.Agent.ask(scope, agent, "Where's A1?")

    assert %{"data" => %{"interrupts" => [%{"reason" => "tool_approval"}]}} =
             until("wardrik.run.interrupted")

    {:ok, _decided} = Wardrik.Agent.approve(scope, agent, "call_1")
    assert_receive {:called, "lookup", _arguments, _meta}

    assert %{"data" => %{"interrupts" => [%{"id" => "call_1", "reason" => "in_doubt"}]}} =
             until("wardrik.run.interrupted")

    refute Process.alive?(first)
    worker(wardrik, "acme/@shop", ["acme/agent/*"], [changing], fn _call -> @shipped end)
    {:ok, _decided} = Wardrik.Agent.approve(scope, agent, "call_1")

    assert_receive {:called, "lookup", _arguments, %{"idempotencyKey" => "call_1"}}
    assert %{"data" => %{"status" => "ok"}} = until_completed()
  end

  defp until_completed do
    receive do
      {WardrikEvents, _log, %{"type" => "wardrik.tool_call.completed"} = event} -> event
      {WardrikEvents, _log, _event} -> until_completed()
    after
      10_000 -> flunk("No wardrik.tool_call.completed came.")
    end
  end
end
