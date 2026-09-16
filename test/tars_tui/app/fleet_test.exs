defmodule TarsTUI.App.FleetTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias Tars.Agent
  alias Tars.Event
  alias Tars.Event.Bus
  alias Tars.Event.Source
  alias Tars.Fleet
  alias Tars.Test.AgentRunners
  alias TarsTUI.App

  setup do
    org = "tui#{System.unique_integer([:positive])}"
    spawn_opts = [org: org, runner: {AgentRunners, :echo, [self(), "ok"]}]
    agent_id = Fleet.key("watched", spawn_opts)
    {:ok, _pid} = Fleet.spawn(agent_id, spawn_opts)
    on_exit(fn -> Fleet.forget(agent_id) end)

    session =
      Breeze.Test.start!(App,
        size: {90, 14},
        start_opts: [
          agent: agent_id,
          agent_id: agent_id,
          spawn_opts: spawn_opts,
          model: "test:model"
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
    assert screen(session) =~ "j/k move · Enter connect · i prompt · Esc back"

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

  test "the panel widens for long names and their node", %{session: session, org: org} do
    key = Fleet.key("assistant_with_a_long_name", org: org)
    on_exit(fn -> Fleet.forget(key) end)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})

    submit(session, "/fleet")

    assert screen(session) =~ "○ assistant_with_a_long_name"
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
    key = "#{org}/_/helper"
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/spawn helper")

    assert screen(session) =~ "spawned and connected to #{key}"
    assert Fleet.whereis(key)
  end

  test "/spawn sends the prompt as this client's first message", %{session: session, org: org} do
    on_exit(fn -> Fleet.forget("#{org}/_/asked") end)

    submit(session, "/spawn asked look into it")

    assert screen(session) =~ "› look into it"
    assert_receive {:turn, [{:user, "look into it"}]}
  end

  test "/connect moves this client onto another agent", %{session: session, org: org} do
    key = "#{org}/_/other"
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
    key = Fleet.key("tooled", org: org)
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
    assert text =~ other <> "  idle"

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
    assert screen(session) =~ "/spawn NAME [node=N] [-- prompt] · type the rest, then Enter"

    type.("helper -- hello there")
    Breeze.Test.input(session, "Enter")

    text = screen(session)
    assert text =~ "spawned and connected to #{Fleet.key("helper", org: org)}"
    assert text =~ "› hello there"
    assert Fleet.whereis(Fleet.key("helper", org: org))
    Fleet.forget(Fleet.key("helper", org: org))
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
    key = Fleet.key("sonnet", org: org)
    config = Tars.LLM.Config.new(model_spec: {:anthropic, model: "claude-sonnet-5"})
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
    Breeze.Test.info(session, Event.new(stale, {:turn_started, ["stale"]}))
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
    key = "#{org}/_/placed"
    on_exit(fn -> Fleet.forget(key) end)
    [short | _host] = node() |> Atom.to_string() |> String.split("@")

    submit(session, "/spawn placed node=#{short}")

    assert screen(session) =~ "spawned and connected to #{key}"
    assert Fleet.whereis(key)
  end

  test "/spawn says so when the node is not there", %{session: session} do
    submit(session, "/spawn nowhere node=elsewhere")

    assert screen(session) =~ ~s(no_such_node, "elsewhere")
  end

  test "/spawn refuses an option it does not know", %{session: session} do
    submit(session, "/spawn odd colour=red")

    assert screen(session) =~ ~s(unknown_options, ["colour"])
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

  test "a restart under the same key is followed and announced", ctx do
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

  test "/move needs a node", %{session: session} do
    submit(session, "/move watched")

    assert screen(session) =~ ":node_required"
  end

  # An agent under `org` that has already answered one question.
  defp spawn_and_ask(org, name, question) do
    key = Fleet.key(name, org: org)
    runner = {AgentRunners, :echo, [self(), "the answer"]}
    {:ok, pid} = Fleet.spawn(key, runner: runner)
    on_exit(fn -> Fleet.forget(key) end)
    :ok = Bus.subscribe(key)

    Agent.ask(pid, question)
    assert_receive %Event{payload: {:turn_finished, _messages}}
    :ok = Bus.unsubscribe(key)

    key
  end

  test "/connect says so when nothing holds the key", %{session: session, org: org} do
    submit(session, "/connect nobody")

    assert screen(session) =~ "no agent at #{org}/_/nobody"
  end

  test "/fleet lists the agents in the transcript", %{session: session, agent_id: agent_id} do
    submit(session, "/fleet")

    assert screen(session) =~ agent_id
  end

  test "/rm NAME shows what would go and removes it on /confirm", %{session: session, org: org} do
    key = Fleet.key("doomed", org: org)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/rm doomed")

    text = screen(session)
    assert text =~ "/rm doomed removes 1 agent, and what they said, for good:"
    assert text =~ key
    assert text =~ "/confirm goes ahead"
    assert Fleet.whereis(key)

    submit(session, "/confirm")

    assert screen(session) =~ "removed #{key} and its store"
    assert Fleet.whereis(key) == nil
    assert {:error, :not_found} = DurableServer.Supervisor.get_server_info(Fleet, key)
  end

  test "anything but /confirm cancels a removal", %{session: session, org: org} do
    key = Fleet.key("spared", org: org)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/rm spared")
    submit(session, "/fleet")
    assert screen(session) =~ "removal cancelled"

    submit(session, "/confirm")
    assert screen(session) =~ "nothing is waiting to be confirmed"
    assert Fleet.whereis(key)
  end

  test "/rm NAME --yes skips the preview", %{session: session, org: org} do
    key = Fleet.key("sure", org: org)
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
    keys = for name <- ["one", "two"], do: Fleet.key(name, org: org)

    for key <- keys do
      {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
      on_exit(fn -> Fleet.forget(key) end)
    end

    submit(session, "/rm #{org}/")

    text = screen(session)
    assert text =~ "removes 2 agents"
    assert Enum.all?(keys, &(text =~ &1))
    assert text =~ "skipping #{agent_id} · you are attached to it"

    submit(session, "/confirm")

    text = screen(session)
    assert text =~ "removed 2 agents and their stores"
    assert Enum.all?(keys, &(Fleet.whereis(&1) == nil))
    assert Fleet.whereis(agent_id)
  end

  test "a target may be a full key, with or without a leading slash", ctx do
    %{session: session, org: org} = ctx
    other = spawn_and_ask(org, "other", "what is up")
    key = Fleet.key("doomed", org: org)
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)

    submit(session, "/connect #{other}")
    assert screen(session) =~ "connected to #{other}"

    submit(session, "/rm /#{key}")
    assert screen(session) =~ "/rm #{key} removes 1 agent"

    submit(session, "/confirm")
    assert screen(session) =~ "removed #{key} and its store"
    assert Fleet.whereis(key) == nil

    submit(session, "/rm some/odd/shape/of/key")
    assert screen(session) =~ "no agent at some/odd/shape/of/key"
  end

  test "/rm NAME says so when nothing holds the key", %{session: session, org: org} do
    submit(session, "/rm nobody")

    assert screen(session) =~ "no agent at #{org}/_/nobody"
  end

  test "/rm says so when a prefix matches nothing", %{session: session} do
    submit(session, "/rm nothing/here/")

    assert screen(session) =~ "nothing running under nothing/here/"
  end

  test "/kill is gone, and says where its jobs went", %{session: session} do
    submit(session, "/kill watched")

    text = screen(session)
    assert text =~ "/kill is gone"
    assert text =~ "/stop interrupts"
    refute_receive {:turn, _}
  end

  test "/stop NAME interrupts another agent and leaves it running", %{session: session, org: org} do
    key = Fleet.key("busy", org: org)
    {:ok, pid} = Fleet.spawn(key, runner: {AgentRunners, :blocking, [self(), "ok"]})
    on_exit(fn -> Fleet.forget(key) end)
    :ok = Bus.subscribe(key)
    Agent.ask(pid, "take your time")
    assert_receive {:turn, _messages, _turn_pid}

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

  test "/help lists the commands", %{session: session} do
    session = Breeze.Test.resize(session, {90, 60})
    submit(session, "/help")

    text = screen(session)
    assert text =~ "/quit"
    assert text =~ "every key and command"
    assert text =~ "Ctrl-X then h/j/k/l"
  end
end
