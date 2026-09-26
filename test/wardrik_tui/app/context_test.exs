defmodule WardrikTUI.App.ContextTest do
  use ExUnit.Case, async: false
  alias Wardrik.{Agent, Event, Fleet}
  alias WardrikTUI.App

  def park_two(%Wardrik.LLM.Turn{scope: scope}) do
    parked = Wardrik.Test.AgentRunners.parked_turn("first")
    second = %{id: "second", name: "second", arguments: %{}}
    calls = parked.calls ++ [Wardrik.Test.AgentRunners.waiting(second, "Second?")]

    %{parked | calls: calls, scope: scope}
  end

  def resume_blocked(owner, %Wardrik.LLM.Turn{} = parked, decisions) do
    send(owner, {:resumer, self(), decisions})
    receive do: (:release -> :ok)

    %{parked | calls: Enum.reject(parked.calls, &Map.has_key?(decisions, &1.id))}
  end

  defp session(key) do
    s =
      Breeze.Test.start!(App,
        size: {100, 30},
        start_opts: [agent: key, agent_id: key],
        global_keybindings: App.keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(s) end)
    screen(s)
    s
  end

  defp screen(s), do: Breeze.Test.render_text!(s)

  defp submit(s, text) do
    screen(s)
    Breeze.Test.event(s, "ask", %{value: text})
    screen(s)
  end

  defp connect_sidebar(s, key) do
    Breeze.Test.event(s, "highlight", %{value: key})
    Breeze.Test.focus(s, "fleet")
    Breeze.Test.input(s, "Enter")
    screen(s)
  end

  test "deleted and recreated agents do not restore deleted conversations" do
    {a, _} = Wardrik.Test.Fleet.start_agent()

    {b, _} =
      Wardrik.Test.Fleet.start_agent(
        context: ReqLLM.Context.new([ReqLLM.Context.user("OLD DELETED HISTORY")])
      )

    s = session(a)
    submit(s, "/connect #{b}")
    submit(s, "/connect #{a}")
    submit(s, "/rm #{b}")
    submit(s, "/confirm")
    {:ok, _} = Fleet.spawn(b, context: ReqLLM.Context.new([ReqLLM.Context.user("NEW HISTORY")]))
    submit(s, "/connect #{b}")
    text = screen(s)
    refute text =~ "OLD DELETED HISTORY"
    assert text =~ "NEW HISTORY"
  end

  test "cursor returns to its original position" do
    {a, _} = Wardrik.Test.Fleet.start_agent()
    {b, _} = Wardrik.Test.Fleet.start_agent()
    s = session(a)
    Enum.each(String.graphemes("abcd"), &Breeze.Test.input(s, &1))
    Breeze.Test.input(s, "ArrowLeft")
    Breeze.Test.input(s, "ArrowLeft")
    connect_sidebar(s, b)
    connect_sidebar(s, a)
    Breeze.Test.input(s, "X")
    assert screen(s) =~ "abXcd"
  end

  test "external deletion invalidates cached drafts and history even with the same message count" do
    {a, _} = Wardrik.Test.Fleet.start_agent()

    {b, _} =
      Wardrik.Test.Fleet.start_agent(
        context: ReqLLM.Context.new([ReqLLM.Context.user("old context")])
      )

    s = session(b)
    Enum.each(String.graphemes("old draft"), &Breeze.Test.input(s, &1))
    connect_sidebar(s, a)
    :ok = Fleet.forget(b)
    {:ok, _} = Fleet.spawn(b, context: ReqLLM.Context.new([ReqLLM.Context.user("new context")]))
    submit(s, "/connect #{b}")
    text = screen(s)
    assert text =~ "new context"
    refute text =~ "old context"
    refute text =~ "old draft"
  end

  test "scrollback and unread messages survive switching until following output" do
    messages = for n <- 1..50, do: ReqLLM.Context.user("message #{n}")

    {a, pid} =
      Wardrik.Test.Fleet.start_agent(
        context: ReqLLM.Context.new(messages),
        runner: {Wardrik.Test.AgentRunners, :echo, [self(), "new answer"]}
      )

    {b, _} = Wardrik.Test.Fleet.start_agent()
    s = session(a)
    Breeze.Test.focus(s, "log")
    Breeze.Test.input(s, "Home")
    assert screen(s) =~ "message 1"
    connect_sidebar(s, b)
    Event.Bus.subscribe(a)
    Agent.ask(pid, "new question")
    assert_receive %Event{payload: {:turn_finished, _}}, 2000
    connect_sidebar(s, a)
    assert screen(s) =~ "message 1"
    assert screen(s) =~ "↓ new output below · End to follow"
    Breeze.Test.focus(s, "log")
    Breeze.Test.input(s, "End")
    assert screen(s) =~ "new answer"
    refute screen(s) =~ "new output below"
  end

  test "prefix deletion still previews its exact targets with --yes" do
    {a, _} = Wardrik.Test.Fleet.start_agent()
    prefix = "review#{System.unique_integer([:positive])}/"
    {b, _} = Wardrik.Test.Fleet.start_agent([], prefix <> "_/other")
    s = session(a)
    submit(s, "/rm #{prefix} --yes")
    assert screen(s) =~ b
    assert screen(s) =~ "/confirm goes ahead"
    assert Fleet.whereis(b)
    submit(s, "/confirm")
    refute Fleet.whereis(b)
  end

  test "snapshot identity survives shutdown but changes after deletion" do
    {key, pid} = Wardrik.Test.Fleet.start_agent()
    original = Agent.snapshot(pid)
    :ok = Fleet.stop(key)
    {:ok, resumed} = Fleet.spawn(key)
    assert Agent.snapshot(resumed).generation == original.generation
    :ok = Fleet.forget(key)
    {:ok, replaced} = Fleet.spawn(key)
    refute Agent.snapshot(replaced).generation == original.generation
  end

  test "the backend rejects stale and concurrent decisions without claiming acceptance" do
    {key, pid} =
      Wardrik.Test.Fleet.start_agent(
        runner: {__MODULE__, :park_two, []},
        resumer: {__MODULE__, :resume_blocked, [self()]}
      )

    assert Agent.decide(pid, %{"first" => :approve}) == {:error, :not_parked}
    Event.Bus.subscribe(key)
    Agent.ask(pid, "work")
    assert_receive %Event{payload: {:turn_parked, _}}, 2000
    assert Agent.decide(pid, %{"absent" => :approve}) == {:error, :stale_decision}
    assert Agent.decide(pid, %{}) == {:error, :stale_decision}
    assert Agent.decide(pid, %{"first" => :approve}) == :ok
    assert_receive {:resumer, running, %{"first" => :approve}}
    assert Agent.decide(pid, %{"second" => :approve}) == {:error, :not_parked}
    send(running, :release)
  end

  test "reconnecting refreshes a missed parked state" do
    {key, pid} = Wardrik.Test.Fleet.start_agent(runner: {__MODULE__, :park_two, []})
    s = session(key)
    :ok = Fleet.stop(key)
    Breeze.Test.info(s, :refresh_fleet)
    {:ok, next} = Fleet.spawn(key)
    assert next != pid
    # Simulate a missed event during disconnection by dropping the TUI subscription.
    # Deliver a refresh after the replacement has parked without delivering its events.
    :sys.replace_state(s.pid, fn term ->
      Event.Bus.unsubscribe(key)
      term
    end)

    Event.Bus.subscribe(key)
    Agent.ask(next, "please work")
    assert_receive %Event{payload: {:turn_parked, _}}, 2000
    Breeze.Test.info(s, :refresh_fleet)
    assert screen(s) =~ "waiting on deploy, second"
  end

  test "second approval is not silently lost while first runs" do
    {key, pid} =
      Wardrik.Test.Fleet.start_agent(
        runner: {__MODULE__, :park_two, []},
        resumer: {__MODULE__, :resume_blocked, [self()]}
      )

    Event.Bus.subscribe(key)
    Agent.ask(pid, "work")
    assert_receive %Event{payload: {:turn_parked, _}}, 2000
    s = session(key)
    submit(s, "/approve 1")
    assert_receive {:resumer, running, %{"first" => :approve}}
    submit(s, "/approve 1")
    refute screen(s) =~ "approved second"
    assert screen(s) =~ "no decision sent"
    Agent.status(pid)
    send(running, :release)
    assert_receive %Event{payload: {:turn_parked, remaining}}, 2000
    assert [{%{id: "second"}, _}] = remaining
    screen(s)
    submit(s, "/approve 1")
    assert_receive {:resumer, second, %{"second" => :approve}}
    send(second, :release)
  end
end
