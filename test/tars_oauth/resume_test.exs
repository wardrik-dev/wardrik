defmodule TarsOAuth.ResumeTest do
  use TarsOAuth.Case, async: false

  alias Tars.Agent
  alias Tars.Credential
  alias Tars.Event
  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Test.AgentRunners
  alias Tars.Test.Fleet
  alias TarsOAuth.Pending

  setup do
    start_supervised!({TarsOAuth.Supervisor, loopback: false})

    :ok
  end

  defp scope(owner, key),
    do: Config.new() |> Scope.root(key, user: owner, credentials: TarsOAuth)

  defp call(id), do: %{id: id, name: "slack__connect", arguments: %{}}

  defp connect(owner, key) do
    stub_server(cimd: true)
    configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])

    {:error, {:authorization_required, url}} =
      Credential.resolve(scope(owner, key), {:user, "github"})

    url
  end

  defp refuse_tokens do
    Req.Test.stub(TarsOAuth.Stub, fn conn ->
      Plug.Conn.resp(conn, 500, "the token endpoint is having a day")
    end)
  end

  describe "continuation/0" do
    test "is nothing outside a call" do
      assert Credential.continuation() == nil
    end

    test "is nothing inside a scope that is not answering a call" do
      :ok = Scope.Context.put(scope("jon", "acme/jon/a"))

      assert Credential.continuation() == nil
    end

    test "approves the call the scope is answering" do
      :ok = Scope.Context.put(scope("jon", "acme/jon/a"), call("call_1"))

      assert Credential.continuation() ==
               {Agent, :decide, ["acme/jon/a", %{"call_1" => :approve}]}
    end
  end

  describe "a flow started inside a parked call" do
    test "remembers the call to answer", %{owner: owner} do
      key = Fleet.key()
      :ok = Scope.Context.put(scope(owner, key), call("call_1"))

      connect(owner, key)

      assert {:ok, flight} = Pending.under_way("github", owner)
      assert flight.resumes == [{Agent, :decide, [key, %{"call_1" => :approve}]}]
    end

    test "remembers a second call that parks while it runs", %{owner: owner} do
      key = Fleet.key()
      :ok = Scope.Context.put(scope(owner, key), call("call_1"))

      first = connect(owner, key)

      :ok = Scope.Context.put(scope(owner, key), call("call_2"))

      assert {:error, {:authorization_required, ^first}} =
               Credential.resolve(scope(owner, key), {:user, "github"})

      assert {:ok, flight} = Pending.under_way("github", owner)

      assert flight.resumes == [
               {Agent, :decide, [key, %{"call_1" => :approve}]},
               {Agent, :decide, [key, %{"call_2" => :approve}]}
             ]
    end

    test "does not remember the same call twice", %{owner: owner} do
      key = Fleet.key()
      :ok = Scope.Context.put(scope(owner, key), call("call_1"))

      connect(owner, key)
      Credential.resolve(scope(owner, key), {:user, "github"})

      assert {:ok, flight} = Pending.under_way("github", owner)
      assert [_one] = flight.resumes
    end

    test "answers it when the callback comes back", %{owner: owner} do
      {key, _agent} =
        Fleet.start_agent(runner: {AgentRunners, :parking, [self(), "call_1"]})

      :ok = Event.Bus.subscribe(key)
      :ok = Scope.Context.put(scope(owner, key), call("call_1"))

      url = connect(owner, key)

      Agent.ask(key, "go")
      assert_receive %Event{payload: {:turn_parked, [{%{id: "call_1"}, _prompt}]}}

      assert {:ok, "github"} = TarsOAuth.finish(state_of(url), "the-code")

      assert_receive %Event{payload: {:turn_resumed, %{"call_1" => :approve}}}
    end
  end

  describe "a callback the token endpoint refuses" do
    test "leaves the flow, and the calls parked on it, where they were", %{owner: owner} do
      key = Fleet.key()
      :ok = Scope.Context.put(scope(owner, key), call("call_1"))

      url = connect(owner, key)
      refuse_tokens()

      assert {:error, _trouble} = TarsOAuth.finish(state_of(url), "the-code")

      assert {:ok, flight} = Pending.under_way("github", owner)
      assert flight.resumes == [{Agent, :decide, [key, %{"call_1" => :approve}]}]
    end

    test "finishes on the same link once the endpoint answers", %{owner: owner} do
      url = connect(owner, "acme/#{owner}/a")
      refuse_tokens()

      assert {:error, _trouble} = TarsOAuth.finish(state_of(url), "the-code")

      stub_server(cimd: true)

      assert {:ok, "github"} = TarsOAuth.finish(state_of(url), "another-code")
      assert TarsOAuth.connected?("github", owner)
    end
  end

  describe "a flow with nobody waiting" do
    test "finishes all the same", %{owner: owner} do
      url = connect(owner, "acme/#{owner}/a")

      assert {:ok, flight} = Pending.under_way("github", owner)
      assert flight.resumes == []
      assert {:ok, "github"} = TarsOAuth.finish(state_of(url), "the-code")
    end

    test "finishes even when the agent it named is gone", %{owner: owner} do
      :ok = Scope.Context.put(scope(owner, "test/_/never-started"), call("call_1"))

      url = connect(owner, "test/_/never-started")

      assert {:ok, "github"} = TarsOAuth.finish(state_of(url), "the-code")
      assert TarsOAuth.connected?("github", owner)
    end
  end
end
