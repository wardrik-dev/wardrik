defmodule Wardrik.Test.Resolver do
  @moduledoc "Resolves each agent as the test set it, by ID, in an `Agent`."
  @behaviour Wardrik.Resolver

  @impl true
  def resolve(%Wardrik.Resolver.Request{agent: id}, agent),
    do: Agent.get(agent, &Map.get(&1, id, {:ok, %Wardrik.Resolved{}}))
end

defmodule Wardrik.Test.Heard do
  @moduledoc "A notify target that tells the test each notice."
  @behaviour Wardrik.Notify

  @impl Wardrik.Notify
  def deliver(notice, opts) do
    send(opts[:test], {:told, opts[:target], notice})
    :ok
  end
end

defmodule Wardrik.ResolverTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Notice
  alias Wardrik.Resolved
  alias WardrikCore.Principal

  @model "anthropic:claude-haiku-4-5"
  @scout "acme/@maria/scout"

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")
    resolved = start_supervised!({Agent, fn -> %{} end})

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        resolver: {Wardrik.Test.Resolver, resolved},
        capabilities: [priced: Wardrik.Test.Priced],
        mcp: [github: [transport: {:stdio, command: "no-such-mcp-server"}]],
        notify: [targets: [audit: {Wardrik.Test.Heard, test: self()}]]
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{wardrik: wardrik, resolved: resolved, scope: owner(wardrik)}
  end

  defp set(resolved, id, resolution), do: Agent.update(resolved, &Map.put(&1, id, resolution))

  defp define(scope, fields),
    do:
      Wardrik.run(
        scope,
        "agent.define",
        Map.merge(%{"agent" => @scout, "model" => @model}, fields)
      )

  defp ask(scope) do
    stub(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, answer("Done.")} end)
    run!(scope, "agent.ask", %{"agent" => @scout, "content" => "Look"})
    until("wardrik.run.completed")
  end

  test "an agent reaches only the servers it's resolved with, never one started by that name",
       %{scope: scope, resolved: resolved} do
    test = self()

    stub(WardrikMCP, :tools, fn _context, opts ->
      send(test, {:servers, opts[:servers]})
      []
    end)

    {:ok, _agent} = define(scope, %{"tools" => ["github/*", "*"]})
    ask(scope)
    assert_receive {:servers, []}

    set(resolved, @scout, {:ok, %Resolved{servers: %{"github" => "github"}}})
    ask(scope)
    assert_receive {:servers, ["github"]}

    set(resolved, @scout, {:ok, %Resolved{servers: %{"code" => "github"}}})
    ask(scope)
    assert_receive {:servers, ["github"]}
  end

  test "an agent acts for the principal it's resolved with, never the one its ID names", %{
    wardrik: wardrik,
    resolved: resolved
  } do
    definition = %{"model" => @model}

    assert {:ok, opts} = Wardrik.Resolution.resolve(wardrik, @scout, definition)
    assert opts[:principal] == nil

    set(resolved, @scout, {:ok, %Resolved{principal: %Principal{id: "user_42"}}})
    assert {:ok, opts} = Wardrik.Resolution.resolve(wardrik, @scout, definition)
    assert opts[:principal] == %Principal{id: "user_42"}
  end

  test "an agent's notices reach only the targets it's resolved with", %{
    wardrik: wardrik,
    resolved: resolved,
    scope: scope
  } do
    assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
             define(scope, %{"notify" => "audit"})

    assert message == "There's no notify target audit here, nor a channel that posts in it."

    set(resolved, @scout, {:ok, %Resolved{notify: %{"alerts" => "audit"}}})
    {:ok, _agent} = define(scope, %{"notify" => "alerts"})

    notice = %Notice{agent: @scout, kind: :failed, at: DateTime.utc_now()}
    assert Wardrik.Notify.deliver(wardrik, "alerts", notice) == :ok
    assert_receive {:told, "audit", ^notice}

    set(resolved, @scout, {:ok, %Resolved{}})
    assert {:skip, _why} = Wardrik.Notify.deliver(wardrik, "alerts", notice)
    assert {:skip, _why} = Wardrik.Notify.deliver(wardrik, "audit", notice)
    refute_received {:told, _target, _notice}
  end

  test "an agent that doesn't resolve isn't started or defined, with the reason", %{
    scope: scope,
    resolved: resolved
  } do
    set(resolved, @scout, {:error, :down})

    assert {:error,
            %Wardrik.Error{type: :unavailable, message: "acme/@maria/scout didn't resolve: :down"}} =
             define(scope, %{})

    gone = Wardrik.Error.new(:not_found, "There's no scout here.")
    set(resolved, @scout, {:error, gone})
    assert define(scope, %{}) == {:error, gone}

    for unread <- [
          %Resolved{principal: "acme/@maria"},
          %Resolved{servers: %{"github" => :github}},
          %Resolved{notify: ["audit"]},
          %Resolved{policy: [nope: ["*"]]}
        ] do
      set(resolved, @scout, {:ok, unread})

      assert {:error,
              %Wardrik.Error{
                type: :invalid_request,
                message: "acme/@maria/scout doesn't resolve: " <> _
              }} =
               define(scope, %{})
    end

    assert Wardrik.run(scope, "agent.read", %{"agent" => @scout}) |> elem(0) == :error
  end

  test "an agent is held to the policy it's resolved with, which its own can't loosen, from when it's refreshed",
       %{wardrik: wardrik, scope: scope, resolved: resolved} do
    answers = fn ->
      {:ok, queue} =
        Agent.start_link(fn -> [calling([call("call_1", "search", %{})]), answer("Done.")] end)

      stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
        {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
      end)
    end

    {:ok, _agent} = define(scope, %{"tools" => ["priced"], "policy" => %{"default" => "allow"}})

    set(resolved, @scout, {:ok, %Resolved{policy: [deny: ["search"]]}})
    assert Wardrik.refresh(wardrik, agents: [@scout]) == []

    answers.()
    run!(scope, "agent.ask", %{"agent" => @scout, "content" => "Look"})
    until("wardrik.tool_call.denied")
    until("wardrik.run.completed")

    set(resolved, @scout, {:error, :down})

    assert Wardrik.refresh(wardrik) == [
             "acme/@maria/scout: acme/@maria/scout didn't resolve: :down"
           ]
  end
end
