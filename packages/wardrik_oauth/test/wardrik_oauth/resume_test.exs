defmodule WardrikOAuth.ResumeTest do
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.Credential
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Calls
  alias Wardrik.Test.Fleet
  alias Wardrik.Test.Script
  alias WardrikOAuth.Pending

  setup do
    start_supervised!(WardrikOAuth.Supervisor)
    stub_server(cimd: true)
    configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])

    :ok
  end

  defp run(owner) do
    id = AgentID.new!("a", org: "acme", user: owner)
    Config.new() |> Run.root(id, host: host())
  end

  # Whoever finishes a flow is recorded as the flow: the provider's authorization.
  defp authorizer, do: Wardrik.Principal.new(:oauth, "github", name: "github authorization")

  # An agent holding a call parked to resolve github for `owner`, as the
  # runtime parks one whose tool names it, and the link it was sent to.
  defp park(owner) do
    {:error, {:authorization_required, link, whose}} =
      Credential.resolve(Calls.tool("tool", %{}, run(owner)), "github")

    assert whose == person("acme", owner)

    {key, agent} =
      Fleet.start_agent(
        config:
          Script.new(
            {AgentRunners, :connecting, [self(), "call_1", link, %{ref: "github", owner: whose}]},
            resume: {AgentRunners, :resuming, [self(), {:ok, []}]}
          )
      )

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "go")
    assert_receive %Event{payload: %Event.TurnParked{calls: [{%{id: "call_1"}, _prompt}]}}

    %{agent: agent, url: link.url}
  end

  defp finish(url), do: WardrikOAuth.finish(state_of(url), "the-code")

  defp refuse_tokens do
    Req.Test.stub(WardrikOAuth.Stub, fn conn ->
      Plug.Conn.resp(conn, 500, "the token endpoint is having a day")
    end)
  end

  describe "a call parked on a flow" do
    test "carries on once the callback comes back, approved by the authorization",
         %{owner: owner} do
      %{url: url} = park(owner)

      assert {:ok, "github"} = finish(url)

      assert_receive %Event{
        payload: %Event.CallDecided{call_id: "call_1", decision: :approve, by: by}
      }

      assert by == authorizer()
      assert_receive %Event{payload: %Event.TurnResumed{decisions: %{"call_1" => :approve}}}
      assert_receive {:resumed, %{"call_1" => :approve}}
    end

    test "stays parked while somebody else connects", %{owner: owner} do
      %{agent: agent} = park(owner)
      [provider] = WardrikOAuth.Provider.all(oauth())

      {:error, {:authorization_required, theirs, _whose}} =
        WardrikOAuth.hold(oauth(), provider, person("acme", "else"), vault: vault())

      assert {:ok, "github"} = finish(theirs.url)

      assert [{%{id: "call_1"}, _prompt}] = Agent.parked(agent)
      refute_received %Event{payload: %Event.TurnResumed{}}
    end

    test "stays parked, on the same link, while the token endpoint refuses", %{owner: owner} do
      %{agent: agent, url: url} = park(owner)
      refuse_tokens()

      assert {:error, _trouble} = finish(url)
      assert {:ok, _flight} = Pending.under_way("github", person("acme", owner))
      assert [{%{id: "call_1"}, _prompt}] = Agent.parked(agent)

      stub_server(cimd: true)

      assert {:ok, "github"} = finish(url)
      assert_receive {:resumed, %{"call_1" => :approve}}
    end
  end

  describe "a flow with nobody waiting" do
    test "finishes all the same", %{owner: owner} do
      [provider] = WardrikOAuth.Provider.all(oauth())

      {:error, {:authorization_required, link, _whose}} =
        WardrikOAuth.hold(oauth(), provider, person("acme", owner), vault: vault())

      assert {:ok, "github"} = finish(link.url)
      assert WardrikOAuth.connected?(vault(), "github", person("acme", owner))
    end
  end
end
