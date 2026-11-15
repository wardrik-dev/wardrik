defmodule WardrikDaemon.CLI.AgentsTest do
  use WardrikDaemon.CLICase, async: true

  setup :start_daemon

  test "lists and shows agents, and their triggers", context do
    assert {0, listed} = wardrik(context, ["ls"])
    assert listed =~ ~r/^triage\s+idle/m

    assert {0, shown} = wardrik(context, ["agent", "show", "triage"])
    assert shown =~ ~r/description\s+Triages\./
    assert shown =~ ~r/policy\s+careful/

    assert {0, triggers} = wardrik(context, ["trigger", "ls", "acme/triage"])
    assert {0, ^triggers} = wardrik(context, ["trigger", "ls", "triage"])
    assert triggers =~ ~r/daily\s+every 0 #{context.later} \* \* \*\s+in 1\dh( \d+m)?\s+Go\./

    assert {0, json} = wardrik(context, ["ls", "--json"])
    triage = id(context, "acme", "triage")
    assert %{"agents" => [%{"id" => ^triage}]} = JSON.decode!(json)

    mine = agent(context, "acme/@jon", "mine")

    ids = fn query ->
      context
      |> wardrik(["ls", "--json" | query])
      |> elem(1)
      |> JSON.decode!()
      |> Map.fetch!("agents")
      |> Enum.map(& &1["id"])
    end

    in_org = ids.(["org:acme"])
    assert Enum.sort(in_org) == Enum.sort([mine, triage])
    assert ids.(["user:acme/@jon"]) == [mine]
    assert ids.(["user:jon"]) == []
    assert ids.(["name:triage", "status:idle"]) == [triage]
    assert ids.(["tri"]) == [triage]
    assert ids.(["org:globex"]) == []
    assert ids.(["attention"]) == []
    assert {0, "No agents match.\n"} = wardrik(context, ["ls", "node:nowhere"])

    assert failing(context, ["agent", "show", "nobody"]) =~ "There's no agent nobody in acme."

    leads = agent(context, "growth", "leads")
    assert {0, listed} = wardrik(context, ["ls", "org:growth"])
    assert listed =~ ~r/^growth\/leads\s+idle/m
    assert ids.(["leads"]) == [leads]
    assert {0, shown} = wardrik(context, ["agent", "show", "growth/leads"])
    assert shown =~ ~r/id\s+#{leads}/
    assert failing(context, ["agent", "cancel", "triage", "nobody"]) =~ "no agent nobody"
    assert failing(context, ["agent", "rm", "triage"]) =~ "declared by a file"
  end

  test "says how each kind of trigger runs, and what it asks", context do
    long = String.duplicate("Read the news. ", 6)

    write(context, "agents/watcher.md", """
    ---
    tools: [files]
    triggers:
      - {name: morning, every: "0 #{context.later_la} * * *", timezone: America/Los_Angeles, prompt_file: CHECKLIST.md}
      - {name: news, every: 1h, feed: https://example.com/feed.xml, prompt: "#{long}"}
      - {name: pushed, webhook: {secret: "${HOOK_SECRET}"}, prompt: Look.}
    ---
    Watch.
    """)

    assert {0, _reloaded} = wardrik(context, ["reload"])
    assert {0, listed} = wardrik(context, ["trigger", "ls", "watcher"])

    assert listed =~
             ~r/morning\s+every 0 #{context.later_la} \* \* \* \(America\/Los_Angeles\)\s+in 1\dh( \d+m)?\s+follows CHECKLIST\.md/

    assert listed =~ ~r/news\s+every 1h\s+in (\d+m|1h)\s+Read the news\./
    assert listed =~ "…"
    assert listed =~ ~r/pushed\s+on a webhook\s+Look\./
  end

  test "asks an agent, and says what it waits on", context do
    answers(context, [
      %{answer("Two cases.") | usage: %{input_tokens: 1_200, output_tokens: 34}}
    ])

    assert {0, "Two cases.\n"} = wardrik(context, ["ask", "triage", "How", "many?"])
    assert {0, listed} = wardrik(context, ["ls"])
    assert listed =~ ~r/^triage\s+idle\s+in \S+( \S+)?\s+1\.2k tokens/m
    assert {0, history} = wardrik(context, ["agent", "history", "triage"])
    assert history =~ "› How many?"
    assert history =~ "Two cases."

    answers(context, [calling("call_1", "echo", %{"text" => "hi"}), answer("Done.")])
    assert {0, waiting} = wardrik(context, ["ask", "triage", "Echo hi"])
    assert waiting =~ ~s(→ echo {"text":"hi"})
    assert waiting =~ "Waiting on a person for 1 call:"
    assert waiting =~ "? echo  call_1"
    assert waiting =~ "Decide with:\n  wardrik approval approve triage call_1\n"
    assert waiting =~ "  wardrik approval deny triage call_1"

    assert {0, parked} = wardrik(context, ["approval", "ls"])
    assert parked =~ ~r/^triage\s+call_1\s+echo/m

    # At a terminal, other commands end by saying what waits.
    tty = %Terminal{tty?: true}

    footed = fn argv ->
      capture_io(fn -> CLI.main(argv, env: context.env, terminal: tty) end)
    end

    assert footed.(["ls"]) =~ "1 call waits on you: wardrik approval approve triage call_1"
    refute footed.(["approval", "ls"]) =~ "waits on you:"
    refute footed.(["ls", "--json"]) =~ "waits on you:"

    assert {0, "Approved call_1.\n"} =
             wardrik(context, ["approval", "approve", "triage", "call_1", "--note", "Go."])

    assert failing(context, ["approval", "deny", "triage", "call_1"]) =~
             "doesn't wait on call_1"

    refute footed.(["ls"]) =~ "waits on you"
  end

  test "follows an agent, showing first what it waits on you for", context do
    answers(context, [calling("call_1", "echo", %{"text" => "hi"})])
    assert {0, _waiting} = wardrik(context, ["ask", "triage", "Echo hi"])

    {:ok, device, _written} = Screen.start_link(notify: self())
    env = context.env
    test = self()

    follower =
      spawn(fn ->
        Process.group_leader(self(), device)
        send(test, {:followed, CLI.main(["follow", "triage"], env: env)})
      end)

    on_exit(fn -> Process.exit(follower, :kill) end)
    screen("triage waits on you:")
    screen("wardrik approval approve triage call_1")

    answers(context, [answer("Echoed.")])
    approve = %{"agent" => id(context, "acme", "triage"), "interrupt" => "call_1"}
    assert {:ok, _approved} = Wardrik.run(context.admin, "agent.approve", approve)
    screen("✓\e[0m echo")
  end

  test "goes through what waits on a person, deciding each", context do
    typing = put_in(context.env["WARDRIK_INPUT"], "1")
    assert {0, "Nothing waits on a person.\n"} = wardrik(typing, ["approval"])

    answers(context, [calling("call_1", "echo", %{"text" => "hi"}), answer("Echoed.")])
    assert {0, _waiting} = wardrik(context, ["ask", "triage", "Echo hi"])

    assert {0, listed} = wardrik(context, ["approval"])
    assert listed =~ ~r/^triage\s+call_1\s+echo/m

    assert {0, reviewed} = wardrik(typing, ["approval"], "y\n")
    assert reviewed =~ "1 of 1 · triage"
    assert reviewed =~ ~s("text": "hi")
    assert reviewed =~ "Approve echo? [y/n, Enter leaves it]"
    assert reviewed =~ "Decided 1 of 1."
  end

  test "asks about a call where the turn stops, and goes on once it's decided", context do
    context = put_in(context.env["WARDRIK_INPUT"], "1")

    answers(context, [calling("call_1", "echo", %{"text" => "hi"}), answer("Echoed.")])
    assert {0, approved} = wardrik(context, ["ask", "triage", "Echo hi"], "maybe\ny\n")
    assert approved =~ "╭─ echo ─"
    refute approved =~ "needs your approval"
    assert approved =~ ~s("text": "hi")
    assert approved =~ "Approve echo? [y/n, Enter leaves it]"
    assert approved =~ "y approves it, n denies it, and Enter leaves it waiting"
    assert approved =~ "✓ echo"
    assert approved =~ "Echoed."
    refute approved =~ "Decide with:"

    answers(context, [calling("call_2", "echo", %{"text" => "no"}), answer("Fine, I won't.")])
    assert {0, denied} = wardrik(context, ["ask", "triage", "Echo no"], "n\nNot now.\n")
    assert denied =~ "Why? The model reads it."
    assert denied =~ "echo was refused: Not now."
    assert denied =~ "Fine, I won't."

    answers(context, [calling("call_3", "echo", %{"text" => "later"})])
    assert {0, left} = wardrik(context, ["ask", "triage", "Echo later"], "\n")
    assert left =~ "  wardrik approval approve triage call_3"
    assert {0, parked} = wardrik(context, ["approval", "ls"])
    assert parked =~ ~r/^triage\s+call_3\s+echo/m

    # A message isn't sent behind a call left waiting; it's asked about first.
    run = fn -> send(self(), {:status, CLI.main(~w(ask triage Hi), env: context.env)}) end

    stderr =
      capture_io(:stderr, fn -> assert capture_io("\n", run) =~ "triage waits on you first:" end)

    assert_received {:status, 1}
    assert stderr =~ "triage answers nothing until those are decided, so it wasn't asked."

    # The message goes into the turn the approval resumes, or into one after it.
    answers(context, [answer("Echoed it."), answer("Echoed later.")])
    assert {0, later} = wardrik(context, ["ask", "triage", "Hi"], "y\n")
    assert later =~ "triage waits on you first:"
    assert later =~ ~r/Echoed (it|later)\./
  end

  test "shows what a turn does on a live line, and sums it up where it stops", context do
    {:ok, device, written} = Screen.start_link([])
    screen = :"screen #{context.test}"
    start_supervised!({Owl.LiveScreen, name: screen, device: device})
    terminal = %Terminal{width: 80, input?: true, live: screen}

    answers(context, [calling("call_1", "echo", %{"text" => "hi"}), answer("Two cases.")])
    context = put_in(context.env["WARDRIK_INPUT"], "1")

    run = fn ->
      send(
        self(),
        {:status, CLI.main(~w(ask triage Echo), env: context.env, terminal: terminal)}
      )
    end

    direct = capture_io("y\n", run)
    assert_received {:status, 0}

    live = Screen.written(written)
    assert direct <> live =~ "→ echo"
    assert live =~ "? waits on you after 0s"
    assert live =~ ~r/✔ \d+s · 1 tool call/
    assert direct =~ "Approve echo?"
    assert direct <> live =~ "Two cases."
  end

  test "seals the key it's given, reads the assistant's file, and asks it", context do
    answers(context, [answer("I turn what you ask for into work that runs.")])
    context = put_in(context.env["MY_KEY"], "sk-given")

    assert {0, output} = wardrik(context, ~w(init --provider anthropic --key-from-env MY_KEY))
    assert output =~ "The daemon runs, and read what init wrote."
    assert output =~ "Sealed ANTHROPIC_API_KEY."
    assert output =~ "Asking the assistant: In two short sentences"
    assert output =~ "I turn what you ask for into work that runs."
    assert {0, secrets} = wardrik(context, ["vault", "ls"])
    assert secrets =~ "ANTHROPIC_API_KEY"
  end
end
