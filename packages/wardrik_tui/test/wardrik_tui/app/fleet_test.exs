defmodule WardrikTUI.App.FleetTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.Event
  alias Wardrik.Event.Bus
  alias Wardrik.Event.Source
  alias Wardrik.Fleet
  alias Wardrik.Test.AgentRunners
  alias WardrikTUI.App

  setup do
    :ok = Fleet.watch()
    org = "tui#{System.unique_integer([:positive])}"
    spawn_opts = [runner: {AgentRunners, :echo, [self(), "ok"]}]
    agent_id = AgentID.new!("watched", org: org)
    {:ok, _pid} = Fleet.spawn(agent_id, spawn_opts)
    on_exit(fn -> Fleet.forget(agent_id) end)

    session =
      Breeze.Test.start!(App,
        size: {90, 14},
        start_opts: [
          agent: agent_id,
          agent_id: agent_id,
          org: org,
          spawn_opts: spawn_opts,
          model: "test:model",
          sidebar_width: 24
        ],
        global_keybindings: App.keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render_text!(session)

    {:ok, session: session, org: org, agent_id: agent_id}
  end

  defp screen(session), do: Breeze.Test.render_text!(session)

  # A frame before the keys, as there always is at a terminal: the prompt is
  # reset when a line is sent and only exists again once a frame has drawn it.
  defp submit(session, text) do
    screen(session)
    Enum.each(String.graphemes(text), &Breeze.Test.input(session, &1))
    Breeze.Test.input(session, "Enter")
    session
  end

  test "the panel lists the agent this client is watching", %{session: session} do
    assert screen(session) =~ "fleet · 1"
    assert screen(session) =~ "› ○ watched"
  end

  test "ctrl-f hides the panel and shows it again, leaving focus where it was", ctx do
    %{session: session} = ctx
    assert screen(session) =~ "fleet · 1"

    ctrl_f(session)
    refute screen(session) =~ "fleet · 1"
    assert Breeze.Test.focused(session) == "prompt"

    ctrl_f(session)
    assert screen(session) =~ "fleet · 1"
    assert Breeze.Test.focused(session) == "prompt"
  end

  test "hiding the panel while it is focused returns to the prompt", %{session: session} do
    focus_fleet(session)
    assert Breeze.Test.focused(session) == "fleet"

    ctrl_f(session)
    assert Breeze.Test.focused(session) == "prompt"
  end

  test "Ctrl-X then l reaches the panel, and h comes back", %{session: session} do
    focus_fleet(session)
    assert Breeze.Test.focused(session) == "fleet"

    assert screen(session) =~
             "j/k · l/h expand · n/a attention · Enter connect · i prompt · Esc back"

    Breeze.Test.input(session, %{"key" => "x", "ctrlKey" => true})
    assert screen(session) =~ "Ctrl-X · h transcript · j prompt · Esc cancel"
    Breeze.Test.input(session, "h")
    assert Breeze.Test.focused(session) == "log"
  end

  test "arrows and enter in the panel connect to the chosen agent", ctx do
    %{session: session, org: org} = ctx
    other = spawn_and_ask(org, "other", "what is up")

    focus_fleet(session)
    # A frame between the focus and the keys, as there always is at a terminal.
    screen(session)
    Breeze.Test.input(session, "ArrowUp")
    Breeze.Test.input(session, "Enter")

    assert screen(session) =~ "connected to #{other}"
    assert screen(session) =~ "› what is up"
    assert Breeze.Test.focused(session) == "prompt"
  end

  test "the panel keeps its width, clipping a long name rather than widening", ctx do
    %{session: session, org: org} = ctx
    key = AgentID.new!("assistant_with_a_long_name", org: org)
    on_exit(fn -> Fleet.forget(key) end)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})

    submit(session, "/fleet")

    text = screen(session)
    assert text =~ "○ assistant_with_…│"
    assert Breeze.Test.focused(session) == "fleet"
  end

  @primary "38;5;4"

  test "the focused pane draws its edge in the primary colour", %{session: session} do
    for {focus, edge} <- [{"prompt", :prompt}, {"log", :transcript}, {"fleet", :fleet}] do
      Breeze.Test.focus(session, focus)
      edges = edges(session)

      assert edges[edge] == @primary, "#{focus} focused, but its edge is #{edges[edge]}"
      refute @primary in Map.values(Map.delete(edges, edge))
    end
  end

  test "tab cycles the prompt, the transcript and the panel, and nothing else", ctx do
    %{session: session} = ctx
    assert Breeze.Test.focused(session) == "prompt"

    focus_after_tabs =
      Enum.map(1..3, fn _tab ->
        Breeze.Test.input(session, "\t")
        screen(session)
        Breeze.Test.focused(session)
      end)

    assert focus_after_tabs == ["log", "fleet", "prompt"]
  end

  # The colour each pane's edge is drawn in: the prompt's top border, the
  # rule under the transcript, and the fleet panel's top border.
  defp edges(session) do
    lines = session |> Breeze.Test.render!() |> String.split("\n")
    [rule, _fleet_bottom] = lines |> Enum.find(&String.contains?(&1, "└")) |> String.split("└")
    [before_fleet, _rest] = lines |> Enum.find(&String.contains?(&1, "┌")) |> String.split("┌")

    %{
      prompt: lines |> Enum.find(&String.contains?(&1, "╭")) |> colours() |> List.first(),
      transcript: rule |> colours() |> List.first(),
      fleet: before_fleet |> colours() |> List.last()
    }
  end

  defp colours(line), do: ~r/38;5;\d+/ |> Regex.scan(line) |> List.flatten()

  defp ctrl_f(session), do: Breeze.Test.input(session, %{"key" => "f", "ctrlKey" => true})

  # The leader, then right: from the prompt that is the panel.
  defp focus_fleet(session) do
    Breeze.Test.input(session, %{"key" => "x", "ctrlKey" => true})
    Breeze.Test.input(session, "l")
    session
  end

  test "/spawn starts an agent beside this client's own and attaches to it", %{
    session: session,
    org: org
  } do
    key = AgentID.new!("helper", org: org)
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/spawn helper")

    assert screen(session) =~ "spawned and connected to #{key}"
    assert Fleet.whereis(key)
  end

  # What a host's :options gives the agents a session starts, here a model,
  # or why one cannot start.
  @doc false
  def given(id, test_pid) do
    send(test_pid, {:options_for, id})

    if id.name == "refused",
      do: {:error, "the defaults name no such tool"},
      else: {:ok, [config: Wardrik.LLM.Config.new(model_spec: "anthropic:claude-sonnet-5")]}
  end

  test "/spawn starts an agent with what :options gives its ID", %{org: org, agent_id: agent_id} do
    session =
      Breeze.Test.start!(App,
        size: {90, 14},
        start_opts: [
          agent: agent_id,
          agent_id: agent_id,
          org: org,
          options: {__MODULE__, :given, [self()]},
          model: "test:model"
        ],
        global_keybindings: App.keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    key = AgentID.new!("helper", org: org)
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/spawn helper")
    assert_receive {:options_for, ^key}
    assert screen(session) =~ "spawned and connected to #{key}"
    assert Agent.status(key).model == "anthropic:claude-sonnet-5"

    submit(session, "/spawn refused")
    assert screen(session) =~ "✗ the defaults name no such tool"
    refute Fleet.whereis(AgentID.new!("refused", org: org))
  end

  test "/spawn sends the prompt as this client's first message", %{session: session, org: org} do
    on_exit(fn -> Fleet.forget(AgentID.new!("asked", org: org)) end)

    submit(session, "/spawn asked look into it")

    assert screen(session) =~ "› look into it"
    assert_receive {:turn, [{:user, "look into it"}]}
  end

  test "/connect moves this client onto another agent", %{session: session, org: org} do
    key = AgentID.new!("other", org: org)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/connect other")

    assert screen(session) =~ "connected to"
    assert screen(session) =~ "› ○ other"
  end

  test "/connect starts the transcript over with that agent's conversation", ctx do
    %{session: session, org: org} = ctx
    other = spawn_and_ask(org, "other", "what is up")
    submit(session, "hello from here")
    assert screen(session) =~ "hello from here"

    submit(session, "/connect other")

    refute screen(session) =~ "hello from here"
    assert screen(session) =~ "› what is up"
    assert screen(session) =~ "⏺ the answer"
    assert Fleet.whereis(other)
  end

  test "attaching replays each tool call and what it returned", %{session: session, org: org} do
    key = AgentID.new!("tooled", org: org)
    on_exit(fn -> Fleet.forget(key) end)

    context =
      Context.new([
        Context.user("how many hits?"),
        Context.assistant("Let me look.",
          tool_calls: [ReqLLM.ToolCall.new("call_1", "web_search", ~s({"query":"lemonade"}))]
        ),
        Context.tool_result_message("web_search", "call_1", %{"ok" => true, "hits" => 3}),
        Context.assistant("",
          tool_calls: [ReqLLM.ToolCall.new("call_2", "deep_research", "{}")]
        ),
        Context.tool_result_message("deep_research", "call_2", %{error: "boom"}, %{is_error: true}),
        Context.assistant("Three, and the second search broke.")
      ])

    {:ok, _pid} =
      Fleet.spawn(key, context: context, runner: {AgentRunners, :echo, [self(), "ok"]})

    session = Breeze.Test.resize(session, {90, 30})
    submit(session, "/connect tooled")

    text = screen(session)
    assert text =~ "› how many hits?"
    assert text =~ "⏺ Let me look."
    assert text =~ ~s(⇢ web_search {"query":"lemonade"})
    assert text =~ ~s(✓ web_search · {"hits":3,"ok":true})
    assert text =~ "⇢ deep_research"
    assert text =~ ~s(✗ deep_research · {"error":"boom"})
    assert text =~ "⏺ Three, and the second search broke."

    submit(session, "/tools")
    text = screen(session)
    assert text =~ "› 1  ✓ web_search  query=lemonade"
    assert text =~ "2  ✗ deep_research"

    Breeze.Test.input(session, "Enter")
    text = screen(session)
    assert text =~ ~s("hits": 3)
    assert text =~ ~s("ok": true)
    Breeze.Test.input(session, "Escape")
  end

  test "connecting back restores the transcript and replays what arrived meanwhile", ctx do
    %{session: session, org: org, agent_id: agent_id} = ctx
    session = Breeze.Test.resize(session, {90, 30})
    other = spawn_and_ask(org, "other", "what is up")
    :ok = Bus.subscribe(agent_id)
    submit(session, "hello from here")
    assert_receive %Event{payload: {:turn_finished, _messages}}

    submit(session, "/connect other")
    refute screen(session) =~ "hello from here"

    # The first agent carries on without this client watching.
    Agent.ask(agent_id, "while you were out")
    assert_receive %Event{payload: {:turn_finished, _messages}}
    :ok = Bus.unsubscribe(agent_id)

    submit(session, "/connect watched")

    text = screen(session)
    assert text =~ "› hello from here"
    assert text =~ "⏺ ok"
    assert text =~ "2 messages arrived while this client was elsewhere"
    assert text =~ "› while you were out"
    assert Fleet.whereis(other)
  end

  test "the palette picks an agent for /connect, and types the rest of /spawn", ctx do
    %{session: session, org: org} = ctx
    other = spawn_and_ask(org, "other", "what is up")
    ctrl_p = fn -> Breeze.Test.input(session, %{"key" => "p", "ctrlKey" => true}) end
    type = fn text -> Enum.each(String.graphemes(text), &Breeze.Test.input(session, &1)) end

    ctrl_p.()
    screen(session)
    type.("connect")
    Breeze.Test.input(session, "Enter")

    text = screen(session)
    assert text =~ "/connect · which agent?"
    assert text =~ "#{other}  idle"

    type.("other")
    Breeze.Test.input(session, "Enter")

    text = screen(session)
    assert text =~ "connected to #{other}"
    assert text =~ "› what is up"
    assert Breeze.Test.focused(session) == "prompt"

    ctrl_p.()
    screen(session)
    type.("spawn")
    Breeze.Test.input(session, "Enter")

    assert screen(session) =~
             "/spawn NAME [node=N] [--bg] [-- prompt] · type the rest, then Enter"

    type.("helper -- hello there")
    Breeze.Test.input(session, "Enter")

    text = screen(session)
    assert text =~ "spawned and connected to #{AgentID.new!("helper", org: org)}"
    assert text =~ "› hello there"
    assert Fleet.whereis(AgentID.new!("helper", org: org))
    Fleet.forget(AgentID.new!("helper", org: org))
  end

  test "a tick redraws a running delegation's elapsed time, and stops once it ends", ctx do
    %{session: session, org: org} = ctx
    session = Breeze.Test.resize(session, {90, 30})
    other = AgentID.new!("other", org: org)
    {:ok, pid} = Fleet.spawn(other, runner: {AgentRunners, :delegating, [self(), "pricing"]})
    on_exit(fn -> Fleet.forget(other) end)
    :ok = Bus.subscribe(other, level: :lifecycle)

    Agent.ask(pid, "go")
    assert_receive {:delegating, branch}
    assert eventually(session, fn -> screen(session) =~ "└ ◐ pricing" end)

    # While a delegation runs the tick keeps coming, so its duration advances.
    Breeze.Test.info(session, :tick)
    assert screen(session) =~ "└ ◐ pricing"

    send(branch, :release)
    assert_receive %Event{payload: {:turn_finished, _messages}}
    assert eventually(session, fn -> screen(session) =~ "└ ✓ pricing" end)

    # Nothing is still going, so the tick asks for no more.
    Breeze.Test.info(session, :tick)
    assert screen(session) =~ "└ ✓ pricing"
  end

  test "an agent's delegations show by themselves, Enter inspects one, h hides them and l shows them",
       ctx do
    %{session: session, org: org} = ctx
    session = Breeze.Test.resize(session, {90, 30})
    other = AgentID.new!("other", org: org)
    runner = {AgentRunners, :delegating, [self(), "pricing"]}
    {:ok, pid} = Fleet.spawn(other, runner: runner)
    on_exit(fn -> Fleet.forget(other) end)
    :ok = Bus.subscribe(other, level: :lifecycle)

    Agent.ask(pid, "go")
    assert_receive {:delegating, branch}
    assert_receive %Event{payload: {:delegation_started, _task}}
    assert eventually(session, fn -> screen(session) =~ "◐ other sub 1/1" end)
    assert screen(session) =~ "└ ◐ pricing"
    assert session.pid in Bus.subscribers(other)

    # The panel lists other, its delegation, then watched; the cursor starts
    # on watched.
    focus_fleet(session)
    Breeze.Test.input(session, "k")
    Breeze.Test.input(session, "Enter")

    text = screen(session)
    assert Breeze.Test.focused(session) == "inspector"
    assert text =~ "pricing · #{other}"
    assert text =~ "◐ running"
    assert text =~ "look into pricing"
    assert text =~ "j/k scroll · i prompt · Esc back"

    send(branch, :release)
    assert_receive %Event{payload: {:turn_finished, _messages}}
    assert eventually(session, fn -> screen(session) =~ "✓ done" end)
    assert screen(session) =~ "found pricing"

    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.focused(session) == "fleet"
    text = screen(session)
    refute text =~ "look into pricing"
    assert text =~ "└ ✓ pricing"
    assert eventually(session, fn -> screen(session) =~ "○ other sub 0/1" end)

    Breeze.Test.input(session, "h")
    text = screen(session)
    refute text =~ "└ ✓ pricing"
    assert text =~ "○ other sub 0/1"
    assert session.pid in Bus.subscribers(other)

    # A refresh leaves a collapsed agent collapsed; l expands it again.
    Breeze.Test.info(session, :refresh_fleet)
    refute screen(session) =~ "└ ✓ pricing"
    Breeze.Test.input(session, "l")
    assert screen(session) =~ "└ ✓ pricing"
  end

  defp eventually(session, check) do
    Wardrik.Test.Fleet.await_update(fn ->
      Breeze.Test.info(session, :refresh_fleet)
      check.()
    end)
  end

  test "an agent that finished while unwatched needs attention until connected to", ctx do
    %{session: session, org: org} = ctx
    other = AgentID.new!("other", org: org)
    {:ok, pid} = Fleet.spawn(other, runner: {AgentRunners, :blocking, [self(), "found it"]})
    on_exit(fn -> Fleet.forget(other) end)

    Agent.ask(pid, "go")
    assert_receive {:turn, _context, turn}
    assert eventually(session, fn -> screen(session) =~ "◐ other" end)

    send(turn, :release)
    assert eventually(session, fn -> screen(session) =~ "! ○ other new result" end)
    assert screen(session) =~ "fleet · 2 · 1 need"

    submit(session, "/next")
    text = screen(session)
    assert text =~ "connected to #{other}"
    assert text =~ "› ○ other"
    refute text =~ "new result"
    refute text =~ "need attention"

    submit(session, "/next")
    assert screen(session) =~ "no agent needs attention"
  end

  test "a parked agent needs attention, and n in the panel moves to it", ctx do
    %{session: session, org: org} = ctx
    parker = AgentID.new!("parker", org: org)
    {:ok, pid} = Fleet.spawn(parker, runner: {AgentRunners, :parking, [self(), "call_1"]})
    on_exit(fn -> Fleet.forget(parker) end)

    Agent.ask(pid, "deploy")
    assert_receive :asked
    assert eventually(session, fn -> screen(session) =~ "! ? parker deploy" end)
    assert screen(session) =~ "fleet · 2 · 1 need"

    focus_fleet(session)
    Breeze.Test.input(session, "n")
    assert :sys.get_state(session.pid).assigns.highlighted == parker

    Breeze.Test.input(session, "a")
    text = screen(session)
    assert text =~ "fleet · 1/2 · 1 need"
    refute text =~ "○ watched"

    Breeze.Test.input(session, "a")
    assert screen(session) =~ "› ○ watched"
  end

  test "/filter narrows the panel, and alone shows every agent again", ctx do
    %{session: session, org: org} = ctx
    alpha = AgentID.new!("alpha", org: org)
    busy = AgentID.new!("busy", org: org)
    {:ok, _pid} = Fleet.spawn(alpha, runner: {AgentRunners, :echo, [self(), "ok"]})
    {:ok, pid} = Fleet.spawn(busy, runner: {AgentRunners, :blocking, [self(), "ok"]})
    on_exit(fn -> Enum.each([alpha, busy], &Fleet.forget/1) end)

    Agent.ask(pid, "go")
    assert_receive {:turn, _context, turn}
    assert eventually(session, fn -> screen(session) =~ "◐ busy" end)

    submit(session, "/filter status:running")
    text = screen(session)
    assert text =~ "the panel shows 1 of 3 agents matching status:running"
    assert text =~ "fleet · 1/3 ·"
    assert text =~ "◐ busy"
    refute text =~ "○ alpha"

    submit(session, "/filter size:large")
    assert screen(session) =~ "size:large is not a filter"

    submit(session, "/filter")
    text = screen(session)
    assert text =~ "the panel shows every agent"
    assert text =~ "○ alpha"

    send(turn, :release)
  end

  test "two agents going by one name are both shown by their whole ID", ctx do
    %{session: session, org: org, agent_id: agent_id} = ctx
    twin = AgentID.new!("watched", org: org <> "b")
    {:ok, _pid} = Fleet.spawn(twin, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(twin) end)

    assert eventually(session, fn -> screen(session) =~ "○ #{org}b/" end)
    assert screen(session) =~ "› ○ #{org}/"

    assert twin.org == org <> "b" and agent_id.org == org
  end

  test "on a narrow terminal the panel is an overlay while it is focused", %{session: session} do
    session = Breeze.Test.resize(session, {60, 20})
    refute screen(session) =~ "fleet · 1"

    ctrl_f(session)
    text = screen(session)
    assert text =~ "fleet · 1"
    assert text =~ "› ○ watched"
    assert Breeze.Test.focused(session) == "fleet"

    Breeze.Test.input(session, "Escape")
    refute screen(session) =~ "fleet · 1"
    assert Breeze.Test.focused(session) == "prompt"

    ctrl_f(session)
    assert screen(session) =~ "fleet · 1"
    ctrl_f(session)
    refute screen(session) =~ "fleet · 1"
  end

  test "a draft is kept per agent across a switch", %{session: session, org: org} do
    _other = spawn_and_ask(org, "other", "what is up")
    Enum.each(String.graphemes("unsent draft"), &Breeze.Test.input(session, &1))
    assert screen(session) =~ "› unsent draft"

    focus_fleet(session)
    screen(session)
    Breeze.Test.input(session, "ArrowUp")
    Breeze.Test.input(session, "Enter")
    assert screen(session) =~ "connected to"
    refute screen(session) =~ "unsent draft"

    focus_fleet(session)
    screen(session)
    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "Enter")
    assert screen(session) =~ "› unsent draft"
  end

  test "the header shows the attached agent's model and usage starts over", ctx do
    %{session: session, org: org} = ctx
    key = AgentID.new!("sonnet", org: org)
    config = Wardrik.LLM.Config.new(model_spec: {:anthropic, model: "claude-sonnet-5"})
    {:ok, _pid} = Fleet.spawn(key, config: config, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    assert screen(session) =~ "glm-5.3-flash"

    submit(session, "/connect sonnet")

    text = screen(session)
    assert text =~ "claude-sonnet-5"
    refute text =~ "glm-5.3-flash"
  end

  test "an event left behind by a previous attachment changes nothing", ctx do
    %{session: session, org: org, agent_id: agent_id} = ctx
    _other = spawn_and_ask(org, "other", "what is up")
    submit(session, "/connect other")

    stale = Source.root(agent_id, name: "turn")

    Breeze.Test.info(
      session,
      Event.new(stale, {:turn_started, [Wardrik.Agent.Message.new("stale")]})
    )

    Breeze.Test.info(session, Event.new(stale, {:result, "stale words\n"}))

    text = screen(session)
    refute text =~ "stale words"
    assert text =~ "idle"
  end

  test "attaching on start shows the conversation so far", %{org: org} do
    key = spawn_and_ask(org, "resumed", "where were we")

    session =
      Breeze.Test.start!(App,
        size: {90, 14},
        start_opts: [agent: key, agent_id: key, model: "test:model"],
        global_keybindings: App.keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    assert screen(session) =~ "› where were we"
    assert screen(session) =~ "⏺ the answer"
  end

  test "/spawn places the agent on the node it is given", %{session: session, org: org} do
    key = AgentID.new!("placed", org: org)
    on_exit(fn -> Fleet.forget(key) end)
    [short | _host] = node() |> Atom.to_string() |> String.split("@")

    submit(session, "/spawn placed node=#{short}")

    assert screen(session) =~ "spawned and connected to #{key}"
    assert Fleet.whereis(key)
  end

  test "/spawn says so when the node is not there", %{session: session} do
    submit(session, "/spawn nowhere node=elsewhere")

    text = screen(session)
    assert text =~ "no node named elsewhere"
    assert text =~ "the cluster has #{node()}"
  end

  test "/spawn refuses an option it does not know", %{session: session} do
    submit(session, "/spawn odd colour=red")

    text = screen(session)
    assert text =~ "colour= is not an option of /spawn"
    assert text =~ "usage: /spawn NAME"
  end

  test "/spawn NAME --bg starts an agent and stays here", ctx do
    %{session: session, org: org, agent_id: agent_id} = ctx
    key = AgentID.new!("worker", org: org)
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/spawn worker --bg look into it")

    text = screen(session)
    assert text =~ "spawned #{key} in the background"
    assert text =~ "attaches"
    assert text =~ "sent to #{key}: look into it"
    assert text =~ to_string(agent_id)
    assert text =~ "› ○ watched"
    assert Fleet.whereis(key)
    assert_receive {:turn, [{:user, "look into it"}]}
  end

  test "/spawn of an agent already running connects rather than starting one", ctx do
    %{session: session, org: org} = ctx
    other = spawn_and_ask(org, "other", "what is up")
    pid = Fleet.whereis(other)

    submit(session, "/spawn other")

    text = screen(session)
    assert text =~ "#{other} was already running · connected to it"
    assert text =~ "› what is up"
    assert Fleet.whereis(other) == pid

    submit(session, "/spawn watched --bg")

    text = screen(session)
    assert text =~ "watched is already running · nothing was started"
    assert text =~ "/connect watched attaches"
  end

  test "/move restarts an agent on the node it is given", ctx do
    %{session: session, agent_id: agent_id} = ctx
    before = Fleet.whereis(agent_id)
    [short | _host] = node() |> Atom.to_string() |> String.split("@")

    submit(session, "/move watched node=#{short}")

    assert screen(session) =~ "moved #{agent_id} to #{node()}"
    assert Fleet.whereis(agent_id) != before
    assert screen(session) =~ "› ○ watched"

    # The client follows the agent to its new process.
    submit(session, "still there?")
    assert_receive {:turn, [{:user, "still there?"}]}
  end

  test "a restart under the same ID is followed and announced", ctx do
    %{session: session, agent_id: agent_id} = ctx
    before = Fleet.whereis(agent_id)

    # The same watch the client holds, so the test knows when the registry
    # has the new process and can ask the client to refresh right then.
    :ok = Fleet.watch()
    :ok = Fleet.stop(agent_id)
    {:ok, restarted} = Fleet.spawn(agent_id, runner: {AgentRunners, :echo, [self(), "back"]})
    assert restarted != before
    assert_receive {:group, _events, _info}, 2_000
    Breeze.Test.info(session, :refresh_fleet)

    assert screen(session) =~ "reconnected to #{agent_id} on #{node()}"

    submit(session, "hello again")
    assert_receive {:turn, [{:user, "hello again"}]}, 2_000
  end

  test "/move NAME without a node says so when there is nowhere to go", %{session: session} do
    submit(session, "/move watched")

    assert screen(session) =~ "#{node()} is the only node"
  end

  test "/move alone asks which agent", %{session: session, agent_id: agent_id} do
    submit(session, "/move")

    text = screen(session)
    assert text =~ "/move · which agent?"
    assert text =~ "#{agent_id}  idle"
    Breeze.Test.input(session, "Escape")
    assert Breeze.Test.focused(session) == "prompt"
  end

  test "/move of a busy agent shows what it would interrupt, and /confirm goes ahead", ctx do
    %{session: session, org: org} = ctx
    busy = AgentID.new!("busy", org: org)
    {:ok, pid} = Fleet.spawn(busy, runner: {AgentRunners, :blocking, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(busy) end)
    [short | _host] = node() |> Atom.to_string() |> String.split("@")

    Agent.ask(pid, "go")
    assert_receive {:turn, _context, turn}
    assert eventually(session, fn -> screen(session) =~ "◐ busy" end)

    submit(session, "/move busy node=#{short}")
    text = screen(session)
    assert text =~ "/move #{busy} restarts it on #{node()}"
    assert text =~ "its turn is running and would be interrupted"
    assert text =~ "/confirm goes ahead"
    assert Fleet.whereis(busy) == pid

    submit(session, "/confirm")
    assert eventually(session, fn -> screen(session) =~ "moved #{busy} to #{node()}" end)
    assert Fleet.whereis(busy) != pid
    send(turn, :release)
  end

  test "anything but /confirm cancels a move", ctx do
    %{session: session, org: org} = ctx
    busy = AgentID.new!("stays", org: org)
    {:ok, pid} = Fleet.spawn(busy, runner: {AgentRunners, :blocking, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(busy) end)
    [short | _host] = node() |> Atom.to_string() |> String.split("@")

    Agent.ask(pid, "go")
    assert_receive {:turn, _context, turn}
    assert eventually(session, fn -> screen(session) =~ "◐ stays" end)

    submit(session, "/move stays node=#{short}")
    submit(session, "/filter")
    assert screen(session) =~ "move cancelled · the agent stays where it is"
    assert Fleet.whereis(busy) == pid
    send(turn, :release)
  end

  # An agent under `org` that has already answered one question.
  defp spawn_and_ask(org, name, question) do
    key = AgentID.new!(name, org: org)
    runner = {AgentRunners, :echo, [self(), "the answer"]}
    {:ok, pid} = Fleet.spawn(key, runner: runner)
    on_exit(fn -> Fleet.forget(key) end)
    :ok = Bus.subscribe(key)

    Agent.ask(pid, question)
    assert_receive %Event{payload: {:turn_finished, _messages}}
    :ok = Bus.unsubscribe(key)

    key
  end

  test "/connect says so when nothing holds the ID", %{session: session, org: org} do
    submit(session, "/connect nobody")

    assert screen(session) =~ "no agent at #{org}/nobody"
  end

  test "/connect alone asks which agent", %{session: session, org: org} do
    other = spawn_and_ask(org, "other", "what is up")

    submit(session, "/connect")
    text = screen(session)
    assert text =~ "/connect · which agent?"
    assert text =~ "#{other}  idle"

    Enum.each(String.graphemes("other"), &Breeze.Test.input(session, &1))
    Breeze.Test.input(session, "Enter")
    assert screen(session) =~ "connected to #{other}"
  end

  test "/connect completes part of a name when one agent holds it", %{session: session, org: org} do
    other = spawn_and_ask(org, "researcher", "what is up")

    submit(session, "/connect resea")

    text = screen(session)
    assert text =~ "connected to #{other}"
    assert text =~ "› what is up"
  end

  test "/connect offers a choice when several agents hold part of a name", ctx do
    %{session: session, org: org} = ctx
    one = spawn_and_ask(org, "alpha_one", "one")
    two = spawn_and_ask(org, "alpha_two", "two")

    submit(session, "/connect alpha")

    text = screen(session)
    assert text =~ "/connect · which agent?"
    assert text =~ "› alpha▏"
    assert text =~ to_string(one)
    assert text =~ to_string(two)
    refute text =~ "watched  idle"

    Breeze.Test.input(session, "ArrowDown")
    Breeze.Test.input(session, "Enter")
    assert screen(session) =~ "connected to #{two}"
  end

  test "/fleet shows the panel and moves into it", %{session: session, agent_id: agent_id} do
    ctrl_f(session)
    refute screen(session) =~ "fleet · 1"

    submit(session, "/fleet")

    text = screen(session)
    assert text =~ "fleet · 1"
    assert text =~ agent_id.name
    assert Breeze.Test.focused(session) == "fleet"
  end

  test "/rm NAME shows what would go and removes it on /confirm", %{session: session, org: org} do
    key = AgentID.new!("doomed", org: org)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/rm doomed")

    text = screen(session)
    assert text =~ "/rm doomed removes 1 agent, and what they said, for good:"
    assert text =~ to_string(key)
    assert text =~ "/confirm goes ahead"
    assert Fleet.whereis(key)

    submit(session, "/confirm")

    assert screen(session) =~ "removed #{key} and its store"
    assert Fleet.whereis(key) == nil
    refute Fleet.stored?(key)
  end

  test "anything but /confirm cancels a removal", %{session: session, org: org} do
    key = AgentID.new!("spared", org: org)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/rm spared")
    submit(session, "/filter")
    assert screen(session) =~ "removal cancelled"

    submit(session, "/confirm")
    assert screen(session) =~ "nothing is waiting to be confirmed"
    assert Fleet.whereis(key)
  end

  test "/rm NAME --yes skips the preview", %{session: session, org: org} do
    key = AgentID.new!("sure", org: org)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/rm sure --yes")

    assert screen(session) =~ "removed #{key} and its store"
    assert Fleet.whereis(key) == nil
  end

  test "/rm never removes the agent this client is attached to, and says so", ctx do
    %{session: session, agent_id: agent_id, org: org} = ctx

    submit(session, "/rm watched")
    assert screen(session) =~ "you are attached to #{agent_id}"

    submit(session, "/rm #{org}/")
    assert screen(session) =~ "you are attached to #{agent_id}"
    assert Fleet.whereis(agent_id)
  end

  test "/rm PREFIX/ lists every agent under it and skips the attached one", ctx do
    %{session: session, agent_id: agent_id, org: org} = ctx
    keys = for name <- ["one", "two"], do: AgentID.new!(name, org: org)

    for key <- keys do
      {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
      on_exit(fn -> Fleet.forget(key) end)
    end

    submit(session, "/rm #{org}/")

    text = screen(session)
    assert text =~ "removes 2 agents"
    assert Enum.all?(keys, &(text =~ to_string(&1)))
    assert text =~ "skipping #{agent_id} · you are attached to it"

    submit(session, "/confirm")

    text = screen(session)
    assert text =~ "removed 2 agents and their stores"
    assert Enum.all?(keys, &(Fleet.whereis(&1) == nil))
    assert Fleet.whereis(agent_id)
  end

  test "a target may be a full ID, with or without a leading slash", ctx do
    %{session: session, org: org} = ctx
    other = spawn_and_ask(org, "other", "what is up")
    key = AgentID.new!("doomed", org: org)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/connect #{other}")
    assert screen(session) =~ "connected to #{other}"

    submit(session, "/rm /#{key}")
    assert screen(session) =~ "/rm #{key} removes 1 agent"

    submit(session, "/confirm")
    assert screen(session) =~ "removed #{key} and its store"
    assert Fleet.whereis(key) == nil

    submit(session, "/rm some/odd/shape/of/id")
    assert screen(session) =~ "some/odd/shape/of/id is not an agent ID"
  end

  test "/rm NAME says so when nothing holds the ID", %{session: session, org: org} do
    submit(session, "/rm nobody")

    assert screen(session) =~ "no agent at #{org}/nobody"
  end

  test "/rm says so when a prefix matches nothing", %{session: session} do
    submit(session, "/rm nothing/@here/")

    assert screen(session) =~ "nothing running under nothing/@here/"
  end

  test "/kill is gone, and says where its jobs went", %{session: session} do
    submit(session, "/kill watched")

    text = screen(session)
    assert text =~ "/kill is gone"
    assert text =~ "/stop interrupts"
    refute_receive {:turn, _}
  end

  test "/stop NAME interrupts another agent and leaves it running", %{session: session, org: org} do
    key = AgentID.new!("busy", org: org)
    {:ok, pid} = Fleet.spawn(key, runner: {AgentRunners, :streaming, [self()]})
    on_exit(fn -> Fleet.forget(key) end)
    :ok = Bus.subscribe(key)
    Agent.ask(pid, "take your time")
    assert_receive {:running, _turn_pid}

    submit(session, "/stop busy")

    assert screen(session) =~ "asked #{key} to stop"
    assert_receive %Event{payload: {:turn_interrupted, _stats}}, 5_000
    assert Fleet.whereis(key)
  end

  test "/stop PREFIX/ interrupts every agent under it", %{session: session, org: org} do
    submit(session, "/stop #{org}/")

    assert screen(session) =~ "asked 1 under #{org}/ to stop"
  end

  test "/shutdown NAME stops an agent and keeps its conversation for /spawn", ctx do
    %{session: session, org: org} = ctx
    key = spawn_and_ask(org, "sleeper", "remember this")

    submit(session, "/shutdown sleeper")

    text = screen(session)
    assert text =~ "shut down #{key}"
    assert text =~ "its conversation is kept"
    assert Fleet.whereis(key) == nil

    submit(session, "/spawn sleeper")

    assert screen(session) =~ "› remember this"
    assert Fleet.whereis(key)
  end

  test "shutting down the attached agent leaves the client waiting, sending nothing", ctx do
    %{session: session, agent_id: agent_id} = ctx

    submit(session, "/shutdown watched")

    text = screen(session)
    assert text =~ "#{agent_id} is not running"
    assert text =~ "nothing typed here is sent"

    submit(session, "hello?")
    assert screen(session) =~ "is not running · nothing was sent"
    refute_receive {:turn, _}

    submit(session, "/spawn watched")
    submit(session, "hello again")
    assert_receive {:turn, [{:user, "hello again"}]}, 2_000
  end

  test "/help opens searchable help, the keys of this pane first, and Enter runs a command",
       ctx do
    %{session: session, org: org} = ctx
    other = spawn_and_ask(org, "other", "what is up")
    session = Breeze.Test.resize(session, {100, 60})
    submit(session, "/help")

    text = screen(session)
    assert text =~ "Help · every key and command · Enter runs a command"
    assert text =~ ~r/prompt · here ─+/
    assert text =~ ~r/Enter\s+send what you typed/
    assert text =~ "Ctrl-X then h/j/k/l"
    assert text =~ ~r/commands ─+/
    assert text =~ "1-28 of 56"
    assert Breeze.Test.focused(session) == "palette"

    # The rest of the list, the other panes' keys and what cannot run now
    # among it, is below the fold.
    Breeze.Test.input(session, "End")
    text = screen(session)
    assert text =~ ~r/\/quit\s+Ctrl-D · leave/
    assert text =~ ~r/transcript ─+/
    assert text =~ ~r/j\/k, Ctrl-U\/D, PageUp\/Down\s+scroll a row/
    assert text =~ ~r/not right now ─+/
    assert text =~ ~r/\/stop \[NAME \| PREFIX\/\]\s+interrupt/

    Enum.each(String.graphemes("conn"), &Breeze.Test.input(session, &1))
    text = screen(session)
    assert text =~ "› /connect [NAME]"
    assert text =~ ~r/Up, Down, Enter\s+choose an agent and connect/
    refute text =~ "/quit"

    Breeze.Test.input(session, "Enter")
    assert screen(session) =~ "/connect · which agent?"

    Enum.each(String.graphemes("other"), &Breeze.Test.input(session, &1))
    Breeze.Test.input(session, "Enter")
    assert screen(session) =~ "connected to #{other}"
    assert Breeze.Test.focused(session) == "prompt"
  end

  test "the cursor steps over the section headings", %{session: session} do
    submit(session, "/help")
    screen(session)

    # The cursor opens on the first key under the first heading, not on it.
    assert screen(session) =~ ~r/› Enter\s+send what you typed/

    # Down through the last key of this pane, then over the heading below it.
    Enum.each(1..4, fn _ -> Breeze.Test.input(session, "ArrowDown") end)
    assert screen(session) =~ ~r/› Ctrl-D\s+quit, with nothing typed/
    Breeze.Test.input(session, "ArrowDown")
    assert screen(session) =~ ~r/› Ctrl-G\s+edit the prompt/

    # And back over it the other way.
    Breeze.Test.input(session, "ArrowUp")
    assert screen(session) =~ ~r/› Ctrl-D\s+quit, with nothing typed/

    # Home and End land on a row that can be chosen, not on a heading.
    Breeze.Test.input(session, "Home")
    assert screen(session) =~ ~r/› Enter\s+send what you typed/
    Breeze.Test.input(session, "End")
    refute screen(session) =~ ~r/› \w+ ─+/
  end

  test "Esc closes help with focus where it was", %{session: session} do
    focus_fleet(session)
    Breeze.Test.input(session, %{"key" => "p", "ctrlKey" => true})
    screen(session)
    Enum.each(String.graphemes("every key"), &Breeze.Test.input(session, &1))
    Breeze.Test.input(session, "Enter")
    assert screen(session) =~ "Help · every key and command"
    assert screen(session) =~ ~r/fleet · here ─+/
    assert screen(session) =~ ~r/Up, Down, Enter\s+choose an agent and connect to it/

    Breeze.Test.input(session, "Escape")
    refute screen(session) =~ "Help · every key"
    assert Breeze.Test.focused(session) == "fleet"
  end
end
