defmodule WardrikDaemon.FrontDoorTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias WardrikDaemon.AgentRecords

  setup :set_mimic_global

  setup context do
    context = dirs(context)

    write(context, "config.yaml", """
    org: acme
    orgs: {growth: {}}
    http: {port: #{free_port()}}
    defaults: {model: #{model()}}
    roles:
      workers: {rules: [{verbs: [create, define, read, ask], kinds: [agent]}]}
    bindings:
      - {org: acme, role: workers, subjects: [agent:assistant, agent:door]}
    """)

    write(context, "policies/makes.yaml", "allow: [agent_create]\n")

    door = """
    description: The front door.
    tools: [agents/*, agent_create]
    policy: makes
    ---
    You make workers.
    """

    write(context, "agents/assistant.md", "---\n" <> door)
    write(context, "agents/door.md", "---\norg: growth\n" <> door)

    start_daemon(context)
  end

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  defp calling(name, args) do
    message =
      ReqLLM.Context.assistant("",
        tool_calls: [ReqLLM.ToolCall.new("call_1", name, JSON.encode!(args))]
      )

    %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
  end

  defp answer(text),
    do: %ReqLLM.Response{
      id: "resp",
      model: "test",
      context: nil,
      message: ReqLLM.Context.assistant(text)
    }

  defp create(context, door, args) do
    answers([calling("agent_create", args), answer("Done.")])
    {:ok, _reply} = Wardrik.Agent.reply(context.admin, door, "Watch our rivals.")
    {:ok, timeline} = Wardrik.run(context.admin, "agent.timeline", %{"agent" => door})
    timeline
  end

  @worker %{
    "name" => "rivals-watch",
    "definition" => %{
      "description" => "rivals-watch: watches rivals.",
      "instructions" => "Watch our rivals."
    }
  }

  test "the front door makes a worker of its own org, by name", context do
    door = id(context, "acme", "assistant")
    create(context, door, @worker)

    assert {:ok, record} = AgentRecords.named(context.daemon_store, "acme", "rivals-watch")
    assert %{org: "acme", owner: "acme"} = record

    assert {:ok, %Wardrik.Definition{description: "rivals-watch: watches rivals."}, _problems} =
             Wardrik.Agent.definition(context.admin, record.id)

    # It's held to its maker's policy, and agents_list describes it.
    agents_list = calling("agents_list", %{})
    answers([agents_list, answer("Listed.")])
    {:ok, _reply} = Wardrik.Agent.reply(context.admin, door, "What runs?")

    {:ok, %{"events" => events}} =
      Wardrik.run(context.admin, "agent.events", %{"agent" => door})

    assert Enum.any?(events, &(inspect(&1) =~ "rivals-watch: watches rivals."))

    # The name is the org's, so a second worker of the name is refused.
    create(context, door, @worker)

    assert [_one] =
             for(
               r <- AgentRecords.in_org(context.daemon_store, "acme"),
               r.name == "rivals-watch",
               do: r
             )
  end

  # acme's binding names a door, but growth's door is no agent of acme.
  test "a front door can't make a worker in an org it isn't bound in", context do
    door = id(context, "growth", "door")
    assert inspect(create(context, door, @worker)) =~ "You may not make agents."

    assert AgentRecords.named(context.daemon_store, "growth", "rivals-watch") == :error
    assert AgentRecords.named(context.daemon_store, "acme", "rivals-watch") == :error

    # Nor can acme's put one elsewhere: its name can't name an org, and its owner is its own.
    acme = id(context, "acme", "assistant")

    assert inspect(create(context, acme, %{@worker | "name" => "growth/rivals-watch"})) =~
             "name"

    assert AgentRecords.named(context.daemon_store, "growth", "rivals-watch") == :error
    assert AgentRecords.in_org(context.daemon_store, "growth") |> Enum.map(& &1.name) == ["door"]
  end
end
