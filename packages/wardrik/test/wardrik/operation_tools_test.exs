defmodule Wardrik.Test.WorkerFile do
  @moduledoc "Declarations that declare `acme/worker`, as an agent file would."
  @behaviour Wardrik.Declarations

  @impl Wardrik.Declarations
  def declared?(_config, id), do: id == "acme/worker"

  @impl Wardrik.Declarations
  def reload(_config), do: []
end

defmodule Wardrik.OperationToolsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        authorizer:
          {Wardrik.Test.Authorizer, test: self(), decide: &Wardrik.Test.Allow.authorize(&1, [])},
        resolver: {Wardrik.Test.Owned, :"wardrik #{context.test}"},
        store: store,
        declarations: {Wardrik.Test.WorkerFile, nil}
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = Wardrik.EventLog.subscribe(Wardrik.events(wardrik), :all)
    %{scope: owner(wardrik)}
  end

  defp model(script) do
    {:ok, steps} = Agent.start_link(fn -> script end)
    test = self()

    stub(ReqLLM, :stream_text, fn _model, messages, opts ->
      said = messages |> List.last() |> text()
      send(test, {:prompted, said, Enum.map(opts[:tools] || [], & &1.name)})
      send(test, {:sent, Enum.map_join(messages, "\n", &text/1)})
      {:ok, Agent.get_and_update(steps, &step(&1, said))}
    end)
  end

  defp step(script, said) do
    {key, response} =
      Enum.find(script, fn {key, _response} -> String.contains?(said, key) end) ||
        raise "no step for: " <> said

    {response, List.keydelete(script, key, 0)}
  end

  defp text(%{content: content}) when is_list(content),
    do: Enum.map_join(content, &(&1 |> Map.get(:text, "") |> to_string()))

  defp text(_message), do: ""

  defp define(scope, id, definition),
    do: run!(scope, "agent.define", Map.put(definition, "agent", id))

  test "reads the deployment without asking, and leaves out what agents/* gives", %{scope: scope} do
    model([
      {"How are things",
       calling([
         call("r0", "agents_list", %{}),
         call("r1", "agent_runs", %{"agent" => "acme/worker"}),
         call("r2", "agent_resolved", %{"agent" => "acme/worker"}),
         call("r3", "deployment_nodes", %{}),
         call("r4", "interrupts_list", %{})
       ])},
      {"\"interrupts\"", answer("All quiet.")}
    ])

    define(scope, "acme/worker", %{"model" => @model})
    define(scope, "acme/ops", %{"model" => @model, "tools" => ["agents/*", "ops/read"]})

    run!(scope, "agent.ask", %{"agent" => "acme/ops", "content" => "How are things?"})
    until("wardrik.run.completed")

    assert_received {:prompted, "How are things?", tools}
    assert "agent_runs" in tools and "deployment_runtime" in tools and "audit_list" in tools
    assert Enum.count(tools, &(&1 == "agent_read")) == 1
    refute Enum.any?(tools, &(&1 in ["agent_approve", "agent_deny", "agent_decide"]))
    refute Enum.any?(tools, &String.starts_with?(&1, ["hook_", "channel_", "agent_stop"]))

    assert %{"runs" => [%{"status" => "completed"}]} =
             run!(scope, "agent.runs", %{"agent" => "acme/ops"})

    # An agent a file declares is marked, since only a person changes it.
    assert_received {:sent, _first}
    assert_received {:sent, after_calls}
    assert after_calls =~ ~s("file":true)
  end

  test "gives a read by name, without the rest", %{scope: scope} do
    model([{"Runs?", answer("None.")}])
    define(scope, "acme/ops", %{"model" => @model, "tools" => ["ops/agent.runs"]})

    run!(scope, "agent.ask", %{"agent" => "acme/ops", "content" => "Runs?"})
    until("wardrik.run.completed")

    assert_received {:prompted, "Runs?", ["agent_runs"]}
  end

  test "asks a person before a change it was given by name", %{scope: scope} do
    model([
      {"Stop the worker", calling([call("s1", "agent_stop", %{"agent" => "acme/worker"})])},
      {"\"asleep\"", answer("Stopped.")}
    ])

    define(scope, "acme/worker", %{"model" => @model})
    define(scope, "acme/ops", %{"model" => @model, "tools" => ["ops/agent.stop"]})

    run!(scope, "agent.ask", %{"agent" => "acme/ops", "content" => "Stop the worker"})
    until("wardrik.run.interrupted")

    assert %{"interrupts" => [%{"id" => "s1", "name" => "agent_stop"}]} =
             run!(scope, "agent.read", %{"agent" => "acme/ops"})

    run!(scope, "agent.approve", %{"agent" => "acme/ops", "interrupt" => "s1"})
    until("wardrik.run.completed")

    assert_received {:authorize,
                     %{
                       actor: {:agent, "acme/ops"},
                       action: "agent.stop",
                       resource: {:agent, "acme/worker"}
                     }}

    assert %{"status" => "asleep"} = run!(scope, "agent.read", %{"agent" => "acme/worker"})
  end

  test "never gives deciding calls, streams, or what agents/* gives", %{scope: scope} do
    for tool <- [
          "ops/agent.approve",
          "ops/hook.deliver",
          "ops/events.list",
          "ops/agent.define",
          "ops/nope"
        ] do
      assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
               Wardrik.run(scope, "agent.define", %{
                 "agent" => "acme/ops",
                 "model" => @model,
                 "tools" => [tool]
               })

      assert message =~ "There's no operation"
    end
  end
end
