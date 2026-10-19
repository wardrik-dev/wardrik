defmodule WardrikTUI.App.ContextTest do
  use ExUnit.Case, async: false
  alias Wardrik.{Agent, Event, Fleet}
  alias Wardrik.Conversation
  alias Wardrik.Conversation.User
  alias Wardrik.Test.Script
  alias WardrikTUI.App

  def park_two(%Wardrik.LLM.Turn{run: run}) do
    parked = Wardrik.Test.AgentRunners.parked_turn("first")
    second = %{id: "second", name: "second", arguments: %{}}
    calls = parked.calls ++ [Wardrik.Test.AgentRunners.waiting(second, "Second?")]

    %{parked | calls: calls, run: run}
  end

  def resume_blocked(owner, %Wardrik.LLM.Turn{} = parked, decisions) do
    send(owner, {:resumer, self(), decisions})
    receive do: (:release -> :ok)

    %{parked | calls: Enum.reject(parked.calls, &Map.has_key?(decisions, &1.id))}
  end

  defp session(id) do
    s =
      Breeze.Test.start!(App,
        size: {100, 30},
        start_opts: [
          agent: id,
          agent_id: id,
          host:
            Wardrik.Host.new(
              store: Wardrik.Test.store(),
              definitions: %Wardrik.Definitions{
                store: Wardrik.Test.store(),
                contexts: %WardrikDefinition.Context{}
              },
              issuer: %WardrikTUI.Test.Root{}
            )
        ],
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

  defp connect_sidebar(s, id) do
    Breeze.Test.event(s, "highlight", %{value: id})
    Breeze.Test.focus(s, "fleet")
    Breeze.Test.input(s, "Enter")
    screen(s)
  end

  test "deleted and recreated agents do not restore deleted conversations" do
    {a, _} = Wardrik.Test.Fleet.start_agent()

    {b, _} =
      Wardrik.Test.Fleet.start_agent(history: Conversation.new([User.new("OLD DELETED HISTORY")]))

    s = session(a)
    submit(s, "/connect #{b}")
    submit(s, "/connect #{a}")
    submit(s, "/rm #{b}")
    submit(s, "/confirm")

    {:ok, _} =
      Fleet.spawn(b,
        history: Conversation.new([User.new("NEW HISTORY")])
      )

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
      Wardrik.Test.Fleet.start_agent(history: Conversation.new([User.new("old context")]))

    s = session(b)
    Enum.each(String.graphemes("old draft"), &Breeze.Test.input(s, &1))
    connect_sidebar(s, a)
    :ok = Fleet.forget(b)

    {:ok, _} =
      Fleet.spawn(b,
        history: Conversation.new([User.new("new context")])
      )

    submit(s, "/connect #{b}")
    text = screen(s)
    assert text =~ "new context"
    refute text =~ "old context"
    refute text =~ "old draft"
  end

  test "scrollback and unread messages survive switching until following output" do
    messages = for n <- 1..50, do: User.new("message #{n}")

    {a, pid} =
      Wardrik.Test.Fleet.start_agent(
        history: Conversation.new(messages),
        config: Script.new({Wardrik.Test.AgentRunners, :echo, [self(), "new answer"]})
      )

    {b, _} = Wardrik.Test.Fleet.start_agent()
    s = session(a)
    Breeze.Test.focus(s, "log")
    Breeze.Test.input(s, "Home")
    assert screen(s) =~ "message 1"
    connect_sidebar(s, b)
    Event.Bus.subscribe(a)
    Agent.ask(pid, "new question")
    assert_receive %Event{payload: %Event.TurnFinished{}}, 2000
    connect_sidebar(s, a)
    assert screen(s) =~ "message 1"
    assert screen(s) =~ "↓ new output below · End to follow"
    Breeze.Test.focus(s, "log")
    Breeze.Test.input(s, "End")
    assert screen(s) =~ "new answer"
    refute screen(s) =~ "new output below"
  end

  test "deletion by a pattern still previews its exact targets with --yes" do
    {a, _} = Wardrik.Test.Fleet.start_agent()
    org = "review#{System.unique_integer([:positive])}"
    {b, _} = Wardrik.Test.Fleet.start_agent([], Wardrik.AgentID.new!("other", org: org))
    s = session(a)
    submit(s, "/rm #{org}/agent/* --yes")
    assert screen(s) =~ to_string(b)
    assert screen(s) =~ "/confirm goes ahead"
    assert Fleet.whereis(b, host: Wardrik.Test.host())
    submit(s, "/confirm")
    refute Fleet.whereis(b, host: Wardrik.Test.host())
  end

  test "snapshot identity survives shutdown but changes after deletion" do
    {id, pid} = Wardrik.Test.Fleet.start_agent()
    original = Agent.snapshot(pid)
    :ok = Fleet.stop(id)
    {:ok, resumed} = Fleet.spawn(id)
    assert Agent.snapshot(resumed).generation == original.generation
    :ok = Fleet.forget(id)
    {:ok, replaced} = Fleet.spawn(id)
    refute Agent.snapshot(replaced).generation == original.generation
  end

  test "the backend rejects stale and concurrent decisions without claiming acceptance" do
    {id, pid} =
      Wardrik.Test.Fleet.start_agent(
        config:
          Script.new({__MODULE__, :park_two, []}, resume: {__MODULE__, :resume_blocked, [self()]})
      )

    assert Agent.decide(
             pid,
             %{"first" => :approve},
             token: Wardrik.Token.root(Wardrik.Principal.new(:terminal, "test"))
           ) ==
             {:error, :not_parked}

    Event.Bus.subscribe(id)
    Agent.ask(pid, "work")
    assert_receive %Event{payload: %Event.TurnParked{}}, 2000

    assert Agent.decide(
             pid,
             %{"absent" => :approve},
             token: Wardrik.Token.root(Wardrik.Principal.new(:terminal, "test"))
           ) ==
             {:error, :stale_decision}

    assert Agent.decide(
             pid,
             %{},
             token: Wardrik.Token.root(Wardrik.Principal.new(:terminal, "test"))
           ) ==
             {:error, :stale_decision}

    assert Agent.decide(
             pid,
             %{"first" => :approve},
             token: Wardrik.Token.root(Wardrik.Principal.new(:terminal, "test"))
           ) == :ok

    assert_receive {:resumer, running, %{"first" => :approve}}

    assert Agent.decide(
             pid,
             %{"second" => :approve},
             token: Wardrik.Token.root(Wardrik.Principal.new(:terminal, "test"))
           ) ==
             {:error, :not_parked}

    send(running, :release)
  end

  test "reconnecting refreshes a missed parked state" do
    {id, pid} = Wardrik.Test.Fleet.start_agent(config: Script.new({__MODULE__, :park_two, []}))
    s = session(id)
    :ok = Fleet.stop(id)
    Breeze.Test.info(s, :refresh_fleet)
    {:ok, next} = Fleet.spawn(id)
    assert next != pid
    # Simulate a missed event during disconnection by dropping the TUI subscription.
    # Deliver a refresh after the replacement has parked without delivering its events.
    :sys.replace_state(s.pid, fn term ->
      Event.Bus.unsubscribe(id)
      term
    end)

    Event.Bus.subscribe(id)
    Agent.ask(next, "please work")
    assert_receive %Event{payload: %Event.TurnParked{}}, 2000
    Breeze.Test.info(s, :refresh_fleet)
    assert screen(s) =~ "waiting on a person to approve deploy and second"
  end

  test "attaching mid-turn says what the agent is doing, and counts every message waiting" do
    {id, pid} =
      Wardrik.Test.Fleet.start_agent(
        config:
          Script.new({Wardrik.Test.AgentRunners, :delegating, [self(), "weighing the options"]})
      )

    Event.Bus.subscribe(id)
    Agent.ask(pid, "please work")
    assert_receive {:delegating, _branch}, 2000

    assert_receive %Event{
      payload: %Event.ActivityChanged{activity: %{doing: %Event.SpanStarted{}}}
    }

    s = session(id)
    assert screen(s) =~ "weighing the options"

    Agent.ask(pid, "from elsewhere", sender: Wardrik.Principal.new(:slack, "U1"))

    assert_receive %Event{
      payload: %Event.ActivityChanged{
        activity: %{doing: %Event.SpanStarted{}, pending: 1}
      }
    }

    assert screen(s) =~ "weighing the options, 1 message waiting"
  end

  test "second approval is not silently lost while first runs" do
    {id, pid} =
      Wardrik.Test.Fleet.start_agent(
        config:
          Script.new({__MODULE__, :park_two, []}, resume: {__MODULE__, :resume_blocked, [self()]})
      )

    Event.Bus.subscribe(id)
    Agent.ask(pid, "work")
    assert_receive %Event{payload: %Event.TurnParked{}}, 2000
    s = session(id)
    submit(s, "/approve 1")
    assert_receive {:resumer, running, %{"first" => :approve}}
    submit(s, "/approve 1")
    refute screen(s) =~ "approved second"
    assert screen(s) =~ "no decision sent"
    Agent.status(pid)
    send(running, :release)
    assert_receive %Event{payload: %Event.TurnParked{calls: remaining}}, 2000
    assert [{%{id: "second"}, _}] = remaining
    screen(s)
    submit(s, "/approve 1")
    assert_receive {:resumer, second, %{"second" => :approve}}
    send(second, :release)
  end
end
