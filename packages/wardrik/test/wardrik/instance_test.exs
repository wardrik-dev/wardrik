defmodule Wardrik.InstanceTest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Event.Log.Entry

  defmodule User do
    @moduledoc false
    defstruct [:org, :id, :email]
  end

  # Each user owns their own agents, and nothing else.
  defmodule Agents do
    @moduledoc false
    use Wardrik, otp_app: :wardrik

    @impl Wardrik
    def principal(%User{org: org, id: id, email: email}), do: %{org: org, id: id, name: email}
  end

  # Each user owns their own agents, and reads and messages their org's.
  defmodule Team do
    @moduledoc false
    use Wardrik, otp_app: :wardrik

    @impl Wardrik
    def principal(%User{org: org, id: id}), do: %{org: org, id: id}

    @impl Wardrik
    def grants(_who), do: [owner: :own, reader: :org, messenger: :org]
  end

  defmodule Unstarted do
    @moduledoc false
    use Wardrik, otp_app: :wardrik

    @impl Wardrik
    def principal(%User{org: org, id: id}), do: %{org: org, id: id}
  end

  # Grants whatever the test puts in the app's env.
  defmodule Granting do
    @moduledoc false
    use Wardrik, otp_app: :wardrik

    @impl Wardrik
    def principal(%User{org: org, id: id}), do: %{org: org, id: id}

    @impl Wardrik
    def grants(_who), do: Application.fetch_env!(:wardrik, :grants)
  end

  defmodule Search do
    @moduledoc false
    @behaviour Wardrik.Plugin

    @impl true
    def attach(host, opts),
      do: Wardrik.Host.register(host, :tools, [{opts[:name], Wardrik.Test.SearchTool}])

    @impl true
    def validate(opts),
      do: if(is_binary(opts[:name]), do: :ok, else: {:error, "it names its tool"})
  end

  defmodule Runs do
    @moduledoc false
    use Wardrik.Listener

    @impl true
    def handle(entry, listener) do
      send(listener.options[:test], {:handled, entry})
      :ok
    end
  end

  # The suite's runtime already runs Wardrik on this node, so each instance
  # is given its host as it would build it, on that runtime's store and
  # model, without starting a second.
  setup_all do
    for module <- [Agents, Team, Granting] do
      Application.put_env(:wardrik, module, store: :memory)
      host = Wardrik.Instance.build(module, module.config())

      Wardrik.Instance.put(module, %{
        host
        | llm: Wardrik.Test.llm(),
          runtimes: Wardrik.Test.runtimes()
      })
    end

    on_exit(fn ->
      for module <- [Agents, Team, Granting] do
        Application.delete_env(:wardrik, module)
        :persistent_term.erase({Wardrik.Instance, module})
      end
    end)
  end

  defp user(org),
    do: %User{org: org, id: System.unique_integer([:positive]), email: "maria@#{org}.example"}

  defp name, do: "support-#{System.unique_integer([:positive])}"

  defp fields,
    do: [
      model: "anthropic:claude-sonnet-5",
      instructions: "Answer briefly.",
      retries: [attempts: 0]
    ]

  defp config(opts), do: Wardrik.Instance.config(Agents, :wardrik, opts)

  describe "config" do
    test "is the app's, with what it leaves out at its defaults" do
      assert [store: :memory] = Keyword.take(Agents.config(), [:store])
      assert Agents.config()[:tools] == []
      assert Agents.config()[:plugins] == []
    end

    test "refuses what it does not take, and needs a store" do
      assert_raise NimbleOptions.ValidationError, fn -> config(store: :nowhere) end
      assert_raise NimbleOptions.ValidationError, fn -> config(tool: []) end

      assert_raise NimbleOptions.ValidationError, fn ->
        Wardrik.Instance.config(Unstarted, :wardrik, [])
      end
    end

    test "keeps credentials in a vault where it gives keys" do
      host = Wardrik.Instance.build(Agents, config(vault: [keys: [WardrikVault.generate_key()]]))
      assert %WardrikVault{} = Wardrik.Host.credentials(host)
    end

    test "reads its policies, as maps or keyword lists, and holds every agent to those held" do
      for policies <- [%{"careful" => %{"ask" => ["search"]}}, [careful: [ask: ["search"]]]] do
        host = Wardrik.Instance.build(Agents, config(policies: policies, held: [:careful]))

        assert %WardrikDefinition.Context{
                 held: ["careful"],
                 policies: %{"careful" => %WardrikPolicy{}}
               } =
                 Wardrik.Host.definitions(host).contexts
      end
    end

    test "attaches each plugin in order, once its options check" do
      host = Wardrik.Instance.build(Agents, config(plugins: [{Search, name: "find"}]))
      assert %{"find" => Wardrik.Test.SearchTool} = Wardrik.Host.tools(host)

      assert_raise ArgumentError, ~r/it names its tool/, fn ->
        Wardrik.Instance.build(Agents, config(plugins: [{Search, name: 1}]))
      end

      assert_raise ArgumentError, ~r/is not a plugin/, fn ->
        Wardrik.Instance.build(Agents, config(plugins: [String]))
      end
    end
  end

  describe "the child" do
    test "is one supervisor" do
      assert %{id: Agents, start: {Agents, :start_link, [[]]}, type: :supervisor} =
               Agents.child_spec([])
    end

    test "won't start where Wardrik already runs, and says what runs it" do
      assert_raise ArgumentError, ~r/Agents can't start: .*started without `use Wardrik`/, fn ->
        Agents.start_link()
      end

      # The test process stands in for Team's supervisor, its name released
      # as the test ends.
      Process.register(self(), Team)

      assert_raise ArgumentError,
                   ~r/Team already runs Wardrik on this node, and a node runs one/,
                   fn ->
                     Agents.start_link()
                   end
    end

    test "an instance that isn't started says so" do
      assert_raise ArgumentError, ~r/Unstarted isn't started/, fn ->
        Unstarted.get(user("acme"), name())
      end
    end
  end

  describe "acting as a user" do
    test "a user defines an agent of their own by name, and reads it" do
      maria = user("acme")
      name = name()

      assert {:ok, %Snapshot{agent: agent}} = Agents.define(maria, name, fields())
      assert agent == AgentID.new!(name, org: "acme", user: maria.id)

      assert {:ok,
              %{definition: %Wardrik.Definition{fields: %{"instructions" => "Answer briefly."}}}} =
               Agents.definition(maria, name)

      assert {:ok, %Snapshot{agent: ^agent}} = Agents.get(maria, name)
      assert %Snapshot{agent: ^agent} = Agents.get!(maria, agent)
    end

    test "asks it, and follows what it writes" do
      maria = user("acme")
      name = name()
      {:ok, %Snapshot{agent: agent}} = Agents.define(maria, name, fields())

      assert :ok = Agents.subscribe(maria, name)
      assert {:ok, %Message{}} = Agents.ask(maria, name, "What changed this week?")
      assert_receive %Entry{log: ^agent}, 5_000
      assert :ok = Agents.unsubscribe(maria, name)

      assert {:ok, events} = Agents.events(maria, name, after: "")
      assert Enum.any?(Enum.take(events, 1), &match?(%Entry{log: ^agent}, &1))
    end

    test "nobody else reaches it, in their org or another" do
      maria = user("acme")
      {:ok, %Snapshot{agent: agent}} = Agents.define(maria, name(), fields())

      for other <- [user("acme"), user("globex")] do
        assert {:error, %Error{type: :not_found}} = Agents.get(other, agent)
        assert {:error, %Error{type: :not_found}} = Team.ask(other, agent, "Hello?")
      end

      assert_raise Error, fn -> Agents.get!(user("acme"), agent) end
    end

    test "an org's agent is reached as {:org, name}, as far as grants/1 says" do
      maria = user("acme")
      name = name()
      agent = AgentID.new!(name, org: "acme")

      root =
        Wardrik.Scope.new(
          Wardrik.Instance.host(Team),
          Wardrik.Token.root(Wardrik.Principal.deployment())
        )

      {:ok, _snapshot} = Wardrik.agent_define(root, agent, Wardrik.Instance.fields(fields()))

      assert {:ok, %Snapshot{agent: ^agent}} = Team.get(maria, {:org, name})
      assert {:ok, %Message{}} = Team.ask(maria, {:org, name}, "Hello?")
      assert {:error, %Error{type: :forbidden}} = Team.define(maria, {:org, name}, fields())

      assert {:error, %Error{type: :not_found}} = Agents.get(maria, {:org, name})
    end

    test "lists the user's own agents, then their org's, or one of them" do
      maria = user("acme")
      {:ok, %Snapshot{agent: own}} = Team.define(maria, name(), fields())

      assert {:ok, listed} = Team.list(maria)
      assert own in Enum.map(listed, & &1.id)
      assert Enum.all?(listed, &(&1.id.org == "acme"))

      assert {:ok, [%{id: ^own}]} = Team.list(maria, only: :own)
      assert {:ok, [%{id: ^own}]} = Agents.list(maria)
      assert {:error, %Error{type: :not_found}} = Agents.list(maria, only: :org)
      assert {:ok, []} = Agents.waiting(maria)
    end

    test "a name that can't be an agent's is refused, and a principal/1 that names nobody raises" do
      assert {:error, %Error{type: :invalid}} = Agents.get(user("acme"), "a/b")

      assert_raise ArgumentError, ~r/principal\/1 answered/, fn ->
        Agents.get(user("a/b"), name())
      end
    end

    test "answers what the host offers no user, rather than nothing" do
      maria = user("acme")

      assert {:error, %Error{type: :unsupported}} = Agents.servers(maria)
      assert {:error, %Error{type: :unsupported}} = Agents.connections(maria)
    end
  end

  describe "an agent's life" do
    test "starts, cancels, stops, clears and forgets an agent, and sets its triggers" do
      maria = user("acme")
      name = name()
      {:ok, _snapshot} = Agents.define(maria, name, fields())

      assert {:ok, %Wardrik.Spawned{}} = Agents.start(maria, name)
      assert :ok = Agents.cancel(maria, name)
      assert {:ok, []} = Agents.calls(maria, name)
      assert {:error, %Error{type: :not_found}} = Agents.kill_call(maria, name, "call-1")
      assert {:ok, %Wardrik.Fleet.Member{asleep: true}} = Agents.stop(maria, name)
      assert {:ok, %Snapshot{}} = Agents.clear(maria, name)

      assert {:ok, _trigger} =
               Agents.put_trigger(maria, name, :hourly, every: "1h", prompt: "Anything new?")

      assert {:ok, _trigger} = Agents.delete_trigger(maria, name, :hourly)

      assert :ok = Agents.forget(maria, name)
      assert {:error, %Error{type: :not_found}} = Agents.get(maria, name)
    end

    test "decides nothing an agent isn't waiting on" do
      maria = user("acme")
      name = name()
      {:ok, _snapshot} = Agents.define(maria, name, fields())

      assert {:error, %Error{type: :conflict}} = Agents.approve(maria, name, "call-1")

      assert {:error, %Error{type: :conflict}} =
               Agents.deny(maria, name, ["call-1"], reason: "No.")

      assert {:error, %Error{type: :conflict}} =
               Agents.decide(maria, name, %{"call-1" => :approve})

      assert {:error, %Error{type: :not_found}} = Agents.authorization(maria, name, "call-1")
    end

    test "answers that the host keeps no servers or accounts, and reaches no org's for a user" do
      maria = user("acme")
      server = [name: "github", url: "https://api.githubcopilot.com/mcp/", auth: "oauth"]

      assert {:error, %Error{type: :not_found}} = Agents.servers(maria, org: true)
      assert {:error, %Error{type: :unsupported}} = Agents.add_server(maria, server)
      assert {:error, %Error{type: :unsupported}} = Agents.remove_server(maria, "github")
      assert {:error, %Error{type: :unsupported}} = Agents.connections(maria)
      assert {:error, %Error{type: :unsupported}} = Agents.connect(maria, "github")
      assert {:error, %Error{type: :unsupported}} = Agents.disconnect(maria, "github")
    end
  end

  describe "the tokens it issues" do
    defp scope(module, id) do
      issuer = Wardrik.Host.issuer(Wardrik.Instance.host(module))
      Wardrik.Issuer.issue(issuer, Wardrik.Principal.new(id), []).scope
    end

    defp reaches(scope), do: for(%{resources: [resource]} <- scope, do: to_string(resource))

    test "a user holds what grants/1 says, and owns their own by default" do
      assert reaches(scope(Agents, "acme/@42")) == ["acme/@42/*"]
      assert reaches(scope(Team, "acme/@42")) == ["acme/@42/*", "acme/agent/*", "acme/agent/*"]
    end

    test "an agent, or a thread of one, reads and messages its owner's agents" do
      assert reaches(scope(Agents, "acme/agent/triage")) == ["acme/agent/*"]

      assert reaches(scope(Agents, "acme/@42/agent/support/thread/1696.1234")) == [
               "acme/@42/agent/*"
             ]
    end

    test "your app reads every agent's events, and anyone else holds nothing" do
      assert [%{actions: ["agent.events", "agent.read"]}] = scope(Agents, "deployment")
      assert scope(Agents, "slack:T1/U2") == []
      assert scope(Agents, "acme/agent/front/trigger/hook") == []
    end

    test "a grant that isn't one raises, naming it" do
      on_exit(fn -> Application.delete_env(:wardrik, :grants) end)

      for grant <- [{:boss, :own}, {:reader, :everywhere}, {:reader, "@x/*"}, :reader] do
        Application.put_env(:wardrik, :grants, [grant])
        assert_raise ArgumentError, ~r/grants\/1 answered/, fn -> scope(Granting, "acme/@42") end
      end
    end
  end

  describe "acting as your app" do
    test "reads the nodes and the audit, reloads, and moves an agent" do
      assert {:ok, %Wardrik.Deployment.Nodes{}} = Agents.nodes()
      assert {:ok, entries} = Agents.audit()
      assert is_list(entries)
      assert {:ok, %{reloaded: _reloaded, failed: _failed}} = Agents.reload()

      {:ok, %Snapshot{agent: agent}} = Agents.define(user("acme"), name(), fields())
      assert {:ok, %Wardrik.Fleet.Member{id: ^agent}} = Agents.move(agent, node())
      assert {:error, %Error{type: :invalid}} = Agents.move("nobody", node())
    end
  end

  test "a listener follows an instance's agents as your app" do
    maria = user("acme")
    name = name()
    {:ok, %Snapshot{agent: agent}} = Agents.define(maria, name, fields())

    start_supervised!(
      {Runs,
       agents: Agents, test: self(), after: "", resources: [Wardrik.AgentAddress.resource(agent)]}
    )

    {:ok, %Message{}} = Agents.ask(maria, name, "Anything new?")
    assert_receive {:handled, %Entry{log: ^agent}}, 5_000
  end

  test "a definition is read from a keyword list, all the way down" do
    assert Wardrik.Instance.fields(
             model: "m",
             tools: ["search"],
             triggers: [daily: [every: "1d"]],
             notify: []
           ) ==
             %{
               "model" => "m",
               "tools" => ["search"],
               "triggers" => %{"daily" => %{"every" => "1d"}},
               "notify" => []
             }
  end
end
