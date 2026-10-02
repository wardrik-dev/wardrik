defmodule WardrikOAuth.ResumeTest do
  use WardrikOAuth.Case, async: false

  alias Wardrik.Agent
  alias Wardrik.Credential
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Fleet
  alias WardrikOAuth.Pending

  setup do
    start_supervised!({WardrikOAuth.Supervisor, loopback: false})

    :ok
  end

  defp scope(owner, key),
    do: Config.new() |> Scope.root(key, user: owner, credentials: WardrikVault)

  defp call(id, owner, key),
    do: Wardrik.Call.tool(%{id: id, name: "slack__connect", arguments: %{}}, scope(owner, key))

  # Whoever finishes a flow is recorded as the flow: the provider's authorization.
  defp oauth, do: %Wardrik.Principal{type: :oauth, id: "github", name: "github authorization"}

  defp connect(owner, key) do
    configured()

    {:error, {:authorization_required, url}} =
      Credential.resolve(call("call_1", owner, key), "github")

    url
  end

  # A user connecting from a surface, with no call waiting on them.
  defp connect_unasked(owner) do
    configured()
    [provider] = WardrikOAuth.Provider.all()
    {:error, {:authorization_required, url}} = WardrikOAuth.hold(provider, {nil, owner})
    url
  end

  defp configured do
    stub_server(cimd: true)
    configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])
  end

  defp refuse_tokens do
    Req.Test.stub(WardrikOAuth.Stub, fn conn ->
      Plug.Conn.resp(conn, 500, "the token endpoint is having a day")
    end)
  end

  describe "continuation/2" do
    test "approves the call it is given, as the principal it is given" do
      assert Credential.continuation(call("call_1", "jon", "acme/@jon/a"), oauth()) ==
               {Agent, :decide, ["acme/@jon/a", %{"call_1" => :approve}, [by: oauth()]]}
    end
  end

  describe "a flow started inside a parked call" do
    test "remembers the call to answer", %{owner: owner} do
      key = Fleet.key()
      connect(owner, key)

      assert {:ok, flight} = Pending.under_way("github", {nil, owner})

      assert flight.resumes == [
               {Agent, :decide, [key, %{"call_1" => :approve}, [by: oauth()]]}
             ]
    end

    test "remembers a second call that parks while it runs", %{owner: owner} do
      key = Fleet.key()
      first = connect(owner, key)

      assert {:error, {:authorization_required, ^first}} =
               Credential.resolve(call("call_2", owner, key), "github")

      assert {:ok, flight} = Pending.under_way("github", {nil, owner})

      assert flight.resumes == [
               {Agent, :decide, [key, %{"call_1" => :approve}, [by: oauth()]]},
               {Agent, :decide, [key, %{"call_2" => :approve}, [by: oauth()]]}
             ]
    end

    test "does not remember the same call twice", %{owner: owner} do
      key = Fleet.key()
      connect(owner, key)
      Credential.resolve(call("call_1", owner, key), "github")

      assert {:ok, flight} = Pending.under_way("github", {nil, owner})
      assert [_one] = flight.resumes
    end

    test "answers it when the callback comes back", %{owner: owner} do
      {key, _agent} =
        Fleet.start_agent(
          runner: {AgentRunners, :parking, [self(), "call_1"]},
          resumer: {AgentRunners, :resuming, [self(), {:ok, []}]}
        )

      :ok = Event.Bus.subscribe(key)
      url = connect(owner, key)

      Agent.ask(key, "go")
      assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, _prompt}]}}

      assert {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

      assert_receive %Event{payload: {:turn_resumed, %{"call_1" => :approve}}}
      assert_receive {:resumed, %{"call_1" => :approve}}
    end
  end

  describe "a callback the token endpoint refuses" do
    test "leaves the flow, and the calls parked on it, where they were", %{owner: owner} do
      key = Fleet.key()
      url = connect(owner, key)
      refuse_tokens()

      assert {:error, _trouble} = WardrikOAuth.finish(state_of(url), "the-code")

      assert {:ok, flight} = Pending.under_way("github", {nil, owner})

      assert flight.resumes == [
               {Agent, :decide, [key, %{"call_1" => :approve}, [by: oauth()]]}
             ]
    end

    test "finishes on the same link once the endpoint answers", %{owner: owner} do
      url = connect(owner, "acme/@#{owner}/a")
      refuse_tokens()

      assert {:error, _trouble} = WardrikOAuth.finish(state_of(url), "the-code")

      stub_server(cimd: true)

      assert {:ok, "github"} = WardrikOAuth.finish(state_of(url), "another-code")
      assert WardrikOAuth.connected?("github", {nil, owner})
    end
  end

  describe "a flow with nobody waiting" do
    test "finishes all the same", %{owner: owner} do
      url = connect_unasked(owner)

      assert {:ok, flight} = Pending.under_way("github", {nil, owner})
      assert flight.resumes == []
      assert {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")
    end

    test "finishes even when the agent it named is gone", %{owner: owner} do
      url = connect(owner, "test/never-started")

      assert {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")
      assert WardrikOAuth.connected?("github", {nil, owner})
    end
  end
end
