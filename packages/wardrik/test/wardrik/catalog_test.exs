defmodule Wardrik.CatalogTest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent.Message
  alias Wardrik.AgentID
  alias Wardrik.Call
  alias Wardrik.Catalog
  alias Wardrik.Catalog.Agents
  alias Wardrik.Catalog.Entry
  alias Wardrik.Catalog.Self
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Event
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Script
  alias Wardrik.Test.Tools.Rules

  # Whoever asks holds the statements a test gives, or, an agent asking, known
  # by its resource, its own: reader and messenger on its owner's agents, as a
  # host's issuer may.
  defmodule Issued do
    @moduledoc false
    defstruct scope: []
  end

  defimpl Wardrik.Issuer, for: Issued do
    def issue(%{scope: scope}, principal, _opts) do
      case String.split(Principal.id(principal), ":") do
        [agent] ->
          owner = Resource.owner(Resource.parse!(agent))

          %Wardrik.Token{
            principal: principal,
            scope: [
              Wardrik.Role.bind([:reader, :messenger], [Resource.parse!("#{owner}/agent/*")])
            ]
          }

        _person ->
          %Wardrik.Token{principal: principal, scope: scope}
      end
    end
  end

  setup do
    agent = acme("watch")
    on_exit(fn -> WardrikTrigger.sync(agent, []) end)
    %{agent: define(agent, %{"description" => "Watches."})}
  end

  defp definitions,
    do: %Definitions{store: Wardrik.Test.store(), contexts: Wardrik.context([])}

  # Keeps `fields` as `id`'s definition, as `source` wrote them.
  defp define(id, fields, source \\ :defaults) do
    context = Definitions.context(definitions(), id)
    {:ok, definition} = Definition.read(fields, id: id, source: source, context: context)
    :ok = Definitions.put(definitions(), definition)
    on_exit(fn -> Definitions.delete(definitions(), id) end)
    id
  end

  defp triggers(id), do: Enum.map(WardrikTrigger.for_agent(id), & &1.name)

  @trigger %{
    "every" => "30m",
    "feed" => "https://rivalco.example/changelog.rss",
    "prompt" => "Look."
  }

  defp run(agent, source, opts \\ []),
    do:
      Wardrik.Test.run(
        Keyword.merge(
          [
            tools: [{source, agent}],
            id: agent,
            host: Wardrik.Test.host(definitions: definitions())
          ],
          opts
        )
      )

  defp allowing(names), do: [hooks: [Wardrik.Hook.new("rules", Rules, allow: names)]]

  defp acme(name), do: AgentID.parse!("acme/#{name}-#{System.unique_integer([:positive])}")

  defp echoing(id, reply) do
    Wardrik.Test.Fleet.start_agent(
      [config: Script.new({AgentRunners, :echo, [self(), reply]})],
      id
    )

    :ok = Event.Bus.subscribe(id)
    id
  end

  describe "an agent's operations on itself" do
    test "are each a tool named for what it does to the agent" do
      agent = AgentID.parse!("acme/watch")
      tools = Self.tools(agent)

      assert Enum.map(tools, & &1.name) == [
               "self_read",
               "self_definition_read",
               "self_ask",
               "self_define",
               "self_trigger_set",
               "self_trigger_remove"
             ]

      set = Enum.find(tools, &(&1.name == "self_trigger_set"))
      entry = Enum.find(Catalog.agent(), &(&1.name == "agent.trigger.set"))
      assert set.description == entry.summary
      assert set.schema == Entry.input(entry)

      assert Self.annotations(agent, "self_trigger_set") == %{gated: true}
      assert Self.annotations(agent, "self_definition_read") == %{}
    end

    test "a change waits on a person, then runs as the agent itself", %{agent: agent} do
      run = run(agent, Self)

      waiting =
        Wardrik.Test.call(run, "self_trigger_set", %{"name" => "rivals", "trigger" => @trigger})

      assert %Call{state: :waiting} = waiting
      assert triggers(agent) == []

      assert %Call{state: :done, result: {:ok, %{"trigger" => %{"name" => "rivals"}}}} =
               Wardrik.Test.resume(run, waiting)

      assert triggers(agent) == ["rivals"]

      assert Wardrik.Test.Audit.about(agent) |> List.last() ==
               {"trigger.set", %{"id" => to_string(AgentID.resource(agent))}}
    end

    test "a thread's call changes its agent", %{agent: agent} do
      define(agent, %{"triggers" => [Map.put(@trigger, "name", "rivals")]})
      assert triggers(agent) == ["rivals"]
      thread = [id: Wardrik.Thread.new!(agent, "thread-1")]

      assert %Call{state: :done, result: {:ok, "done"}} =
               agent
               |> run(Self, allowing(["self_trigger_remove"]) ++ thread)
               |> Wardrik.Test.call("self_trigger_remove", %{"name" => "rivals"})

      assert triggers(agent) == []
    end

    test "a read runs without waiting on anyone", %{agent: agent} do
      assert %Call{
               state: :done,
               result: {:ok, %{"definition" => %{"description" => "Watches."}, "missing" => []}}
             } = agent |> run(Self) |> Wardrik.Test.call("self_definition_read", %{})
    end

    test "answers what does not read, or what another surface declares, as it would there",
         %{agent: agent} do
      assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "invalid_request"}}}} =
               agent
               |> run(Self, allowing(["self_trigger_set"]))
               |> Wardrik.Test.call("self_trigger_set", %{"name" => "x"})

      filed = define(acme("filed"), %{}, {:file, "agents/filed.md"})

      assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "conflict"}}}} =
               filed
               |> run(Self, allowing(["self_trigger_set"]))
               |> Wardrik.Test.call("self_trigger_set", %{
                 "name" => "rivals",
                 "trigger" => @trigger
               })
    end
  end

  describe "an agent's operations on the agents of its org" do
    test "are each a tool taking the agent it acts on, and those on them all" do
      agent = AgentID.parse!("acme/front")
      tools = Agents.tools(agent)

      assert Enum.map(tools, & &1.name) == [
               "agent_read",
               "agent_definition_read",
               "agent_ask",
               "agent_define",
               "agent_trigger_set",
               "agent_trigger_remove",
               "agents_list"
             ]

      for tool <- tools, tool.name != "agents_list" do
        assert %{"required" => ["agent" | _rest], "properties" => %{"agent" => _agent}} =
                 tool.schema

        root = JSV.build!(tool.schema)

        for example <- tool.schema["examples"],
            do: assert({:ok, _valid} = JSV.validate(example, root))
      end

      list = Enum.find(tools, &(&1.name == "agents_list"))
      assert [%Entry{name: "agents.list"} = listing] = Catalog.fleet()
      assert list.schema == Entry.input(listing)
      assert Agents.annotations(agent, "agent_ask") == %{gated: true}
      assert Agents.annotations(agent, "agent_define") == %{gated: true}
      assert Agents.annotations(agent, "agents_list") == %{}
    end

    test "an ask is answered back to the agent that asked, holding what the delegate read" do
      front = echoing(acme("front"), "Noted.")
      reconciler = echoing(acme("reconciler"), "Two are open.")

      :ok =
        Wardrik.Agent.ask(reconciler, "Read this page.",
          labels: ["outside"],
          host: Wardrik.Test.host()
        )

      assert_receive %Event{payload: %Event.TurnFinished{}, source: %{agent_id: ^reconciler}}

      run = run(front, Agents, allowing(["agent_ask"]))

      assert %Call{state: :done, result: {:ok, %{"message" => %{"id" => id}}}} =
               Wardrik.Test.call(run, "agent_ask", %{
                 "agent" => reconciler.name,
                 "content" => "Which deposits are open?"
               })

      assert_receive %Event{
        payload: %Event.MessageQueued{
          message: %Message{text: "Which deposits are open?", reply_to: [^front]}
        },
        source: %{agent_id: ^reconciler}
      }

      assert_receive %Event{
                       payload: %Event.MessageQueued{message: %Message{} = answer},
                       source: %{agent_id: ^front}
                     },
                     5_000

      assert answer.id == "answer:" <> id
      assert answer.text =~ "Two are open."
      assert answer.labels == ["outside"]
      assert Principal.id(answer.sender) == to_string(AgentID.resource(reconciler))

      assert_receive %Event{payload: %Event.TurnFinished{}, source: %{agent_id: ^front}}, 5_000
    end

    test "a read of an agent labels the call with what its history holds" do
      front = acme("front")
      reconciler = echoing(define(acme("reconciler"), %{"description" => "Watches."}), "Read.")

      :ok =
        Wardrik.Agent.ask(reconciler, "Read this page.",
          labels: ["outside"],
          host: Wardrik.Test.host()
        )

      assert_receive %Event{payload: %Event.TurnFinished{}, source: %{agent_id: ^reconciler}}

      assert %Call{state: :done, labels: ["outside"], result: {:ok, %{"labels" => ["outside"]}}} =
               front
               |> run(Agents)
               |> Wardrik.Test.call("agent_read", %{"agent" => reconciler.name})

      assert %Call{
               state: :done,
               labels: [],
               result: {:ok, %{"definition" => %{"description" => "Watches."}}}
             } =
               front
               |> run(Agents)
               |> Wardrik.Test.call("agent_definition_read", %{"agent" => reconciler.name})
    end

    test "a worker it defines is held to its own hooks, ahead of the worker's" do
      front = acme("front")
      worker = acme("worker")

      on_exit(fn ->
        Wardrik.Fleet.forget(worker)
        Definitions.delete(definitions(), worker)
      end)

      hooks = [Wardrik.Hook.new("front", Rules, allow: ["agent_define"])]
      run = run(front, Agents, hooks: hooks)

      assert %Call{state: :done, result: {:ok, %{"agent" => %{"id" => id}}}} =
               Wardrik.Test.call(run, "agent_define", %{
                 "agent" => worker.name,
                 "definition" => %{"instructions" => "Reconcile."}
               })

      assert id == to_string(worker)

      assert {:ok,
              %Definition{
                fields: %{"instructions" => "Reconcile."},
                source: {:api, token},
                held: ^hooks
              }} = Definitions.get(definitions(), worker)

      assert token.policy == :none
      assert token.principal == Principal.new(to_string(AgentID.resource(front)))

      assert token.scope == [
               Wardrik.Role.bind([:reader, :messenger, :definer], [
                 Resource.parse!("acme/agent/*")
               ])
             ]

      %{user_state: state} =
        :sys.get_state(Wardrik.Fleet.whereis(worker, host: Wardrik.Test.host()))

      assert Keyword.fetch!(state.run_opts, :hooks) == hooks

      assert Wardrik.Test.Audit.about(worker) |> List.last() ==
               {"agent.defined", %{"id" => to_string(AgentID.resource(front))}}
    end

    test "reaches its own org and no other" do
      front = acme("front")
      inside = echoing(acme("inside"), "ok")

      outside =
        echoing(AgentID.parse!("other/outside-#{System.unique_integer([:positive])}"), "ok")

      assert %Call{state: :done, result: {:ok, %{"agents" => agents}}} =
               front |> run(Agents) |> Wardrik.Test.call("agents_list", %{})

      ids = Enum.map(agents, & &1["id"])
      assert to_string(inside) in ids
      refute to_string(outside) in ids

      assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "not_found"}}}} =
               front
               |> run(Agents)
               |> Wardrik.Test.call("agent_read", %{"agent" => to_string(outside)})

      assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "invalid_request"}}}} =
               front |> run(Agents) |> Wardrik.Test.call("agent_read", %{})

      assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "invalid_request"}}}} =
               front
               |> run(Agents)
               |> Wardrik.Test.call("agent_read", %{"agent" => "a/b/c/d/e"})
    end

    test "names a thread's agent where the call is on its definition or triggers" do
      books = acme("books")
      thread = "#{books}/C1-17.1"

      assert %Call{state: :done, result: {:error, %{"error" => error}}} =
               acme("front")
               |> run(Agents)
               |> Wardrik.Test.call("agent_definition_read", %{"agent" => thread})

      assert error == %{
               "type" => "invalid_request",
               "message" =>
                 "#{thread} is a thread of #{books}, which holds its definition and triggers; " <>
                   "name #{books} instead."
             }
    end

    test "reads and messages only what whoever asked may, and changes as itself" do
      front = acme("front")
      inside = echoing(acme("inside"), "ok")
      outside = echoing(acme("outside"), "ok")
      worker = acme("worker")

      on_exit(fn ->
        Wardrik.Fleet.forget(worker)
        Definitions.delete(definitions(), worker)
      end)

      one = Wardrik.Role.bind([:reader, :messenger], [AgentID.resource(inside)])

      run =
        run(front, Agents,
          host: Wardrik.Test.host(definitions: definitions(), issuer: %Issued{scope: [one]}),
          sender: Principal.new("chat:U1"),
          hooks: [Wardrik.Hook.new("front", Rules, allow: ["agent_define"])]
        )

      assert %Call{state: :done, result: {:ok, _snapshot}} =
               Wardrik.Test.call(run, "agent_read", %{"agent" => inside.name})

      assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "not_found"}}}} =
               Wardrik.Test.call(run, "agent_read", %{"agent" => outside.name})

      assert %Call{state: :done, result: {:ok, %{"agent" => %{"id" => id}}}} =
               Wardrik.Test.call(run, "agent_define", %{
                 "agent" => worker.name,
                 "definition" => %{"instructions" => "Reconcile."}
               })

      assert id == to_string(worker)
    end

    test "an agent that asks another reads and messages for it what its host issues it" do
      asking = acme("asking")
      front = acme("front")
      inside = echoing(acme("inside"), "ok")

      jons =
        echoing(
          AgentID.new!("mine-#{System.unique_integer([:positive])}", org: "acme", user: "jon"),
          "ok"
        )

      run =
        run(front, Agents,
          host: Wardrik.Test.host(definitions: definitions(), issuer: %Issued{}),
          sender: Principal.new(to_string(AgentID.resource(asking)))
        )

      assert %Call{state: :done, result: {:ok, _snapshot}} =
               Wardrik.Test.call(run, "agent_read", %{"agent" => inside.name})

      assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "not_found"}}}} =
               Wardrik.Test.call(run, "agent_read", %{"agent" => "@jon/" <> jons.name})
    end

    test "reaches none of its org's users' agents, and a user's agent none of the org's" do
      front = acme("front")
      org = front.org

      jons =
        echoing(
          AgentID.new!("mine-#{System.unique_integer([:positive])}", org: org, user: "jon"),
          "ok"
        )

      assert %Call{state: :done, result: {:ok, %{"agents" => agents}}} =
               front |> run(Agents) |> Wardrik.Test.call("agents_list", %{})

      refute to_string(jons) in Enum.map(agents, & &1["id"])

      assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "not_found"}}}} =
               front
               |> run(Agents)
               |> Wardrik.Test.call("agent_read", %{"agent" => "@jon/" <> jons.name})

      assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "not_found"}}}} =
               jons
               |> run(Agents)
               |> Wardrik.Test.call("agent_read", %{"agent" => front.name})
    end
  end
end
