defmodule WardrikDaemon.CLI.SecretsTest do
  use WardrikDaemon.CLICase, async: true

  setup :start_daemon

  test "asks at a terminal, those with a key here first, and takes a key unseen", context do
    context = put_in(context.env["WARDRIK_INPUT"], "1")
    keyed = Map.put(context.env, "ANTHROPIC_API_KEY", "sk-here")

    assert {0, output} = wardrik(%{context | env: keyed}, ~w(init --no-ask), "1\n\n")
    assert output =~ "Found ANTHROPIC_API_KEY here."
    assert output =~ "1. anthropic, whose ANTHROPIC_API_KEY is set here"
    assert output =~ "Which model? claude-haiku-4-5 unless you name another."
    assert output =~ "ANTHROPIC_API_KEY is set here, so it's sealed in the vault"
    assert output =~ "Sealed ANTHROPIC_API_KEY."

    assert {0, output} =
             wardrik(context, ~w(init --provider anthropic --no-ask), "nope\n\nsk-typed\n")

    assert output =~ "anthropic has no model nope."
    assert output =~ "ANTHROPIC_API_KEY, not shown as you type:"
    refute output =~ "sk-typed"
    assert output =~ "Sealed ANTHROPIC_API_KEY."
  end

  test "says why an answer failed", context do
    Wardrik.Testing.Model.answer(context.fake, [{:status, 500}])

    assert failing(context, ["ask", "triage", "Hi"]) =~ "The turn failed."
  end

  test "takes a message written in the editor, or a secret typed unseen", context do
    # $VISUAL goes to the shell as it's set, so its path has no space, as the test's root does.
    editor =
      Path.join(System.tmp_dir!(), "wardrik-editor-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(editor) end)
    File.write!(editor, "#!/bin/sh\nprintf 'How many?\\n%s' \"$(cat \"$1\")\" > \"$1\"\n")
    File.chmod!(editor, 0o755)
    typing = put_in(context.env["WARDRIK_INPUT"], "1")

    answers(context, [answer("Two cases.")])

    assert {0, "Two cases.\n"} =
             wardrik(put_in(typing.env["VISUAL"], editor), ["ask", "triage"])

    assert {0, history} = wardrik(context, ["agent", "history", "triage"])
    assert history =~ "› How many?"
    refute history =~ "<!--"

    File.write!(editor, "#!/bin/sh\n: > \"$1\"\n")

    assert failing(put_in(typing.env["VISUAL"], editor), ["ask", "triage"]) =~
             "The message was empty, so nothing was sent."

    assert failing(put_in(typing.env["VISUAL"], "no-such-editor"), ["ask", "triage"]) =~
             "There's no no-such-editor here to write the message in. Set $VISUAL or $EDITOR"

    assert failing(put_in(typing.env["VISUAL"], "no-such-editor"), ["ask", "triage"]) =~
             "There's no no-such-editor here to write the message in. Set $VISUAL or $EDITOR"

    assert failing(context, ["ask", "triage"]) =~ "Give the message: wardrik ask AGENT MESSAGE"

    assert {0, typed} = wardrik(typing, ~w(vault put TYPED --for api_key), "sk-typed\n")
    assert typed =~ "TYPED, not shown as you type:"
    refute typed =~ "sk-typed"
  end

  test "seals, lists and removes secrets", context do
    assert {0, "Sealed GITHUB_TOKEN.\n"} =
             wardrik(context, ~w(vault put GITHUB_TOKEN --org acme --for header), "ghp_1\n")

    vault =
      context.wardrik
      |> Wardrik.Instance.fetch!()
      |> Wardrik.vault()

    assert {:ok, "ghp_1"} =
             Wardrik.Vault.fetch(vault, %Wardrik.Principal{id: "acme"}, "GITHUB_TOKEN")

    assert {0, "Sealed MINE.\n"} =
             wardrik(context, ~w(vault put MINE --user jon --for api_key), "x\n")

    assert {0, "Sealed DEPLOY.\n"} =
             wardrik(context, ~w(vault put DEPLOY --for signing_secret), "d\n")

    assert failing(context, ~w(vault put EMPTY --for api_key)) =~ "Give the value on stdin"
    assert failing(context, ~w(vault put LOOSE)) =~ "Say what LOOSE is for"

    assert {0, listed} = wardrik(context, ["vault", "ls", "--org", "acme"])
    assert listed =~ ~r/GITHUB_TOKEN\s+header/

    assert {0, "Removed GITHUB_TOKEN.\n"} =
             wardrik(context, ["vault", "rm", "GITHUB_TOKEN", "--org", "acme"])
  end

  test "reloads, says where it runs, and lists what people changed", context do
    assert {0, "Read the agent files again on " <> _nodes} =
             wardrik(context, ["reload"])

    assert {0, "Read the agent files again on " <> _nodes} =
             wardrik(context, ["reload", "triage"])

    write(context, "agents/broken.md", "---\ntools: [nope]\n---\n")
    assert {0, reloaded} = wardrik(context, ["reload"])
    assert reloaded =~ "! Wardrik didn't define broken."
    assert reloaded =~ "broken.md: "

    triage = id(context, "acme", "triage")
    {:ok, _stopped} = Wardrik.run(context.admin, "agent.stop", %{"agent" => triage})
    wardrik = Wardrik.Instance.fetch!(context.wardrik)
    durable = Wardrik.Store.scope(wardrik.store, "durable")
    agents = Wardrik.agents(wardrik)
    key = WardrikCore.saved_key(agents, {triage, nil})
    {value, vsn} = Wardrik.Store.lookup(durable, key)
    parked = %{"reason" => %{"type" => "gone_reason", "version" => 1, "value" => %{}}}
    parked = Map.merge(parked, %{"messages" => [], "span" => nil, "measurements" => %{}})
    gone = %{value["state"] | "state" => "waiting", "parked" => parked}
    {:ok, _vsn} = Wardrik.Store.put(durable, key, %{value | "state" => gone}, if_vsn: vsn)

    assert {0, reloaded} = wardrik(context, ["reload"])

    assert reloaded =~
             "! Wardrik started triage over. #{context.env["WARDRIK_CONFIG_DIR"]}/agents/triage.md: #{triage} started over, as its saved state couldn't be read: it holds a gone_reason, which none of its middleware or capabilities reads."

    assert {0, status} = wardrik(context, ["status"])
    assert status =~ "Wardrik runs at http://127.0.0.1:"
    assert {0, audit} = wardrik(context, ["audit"])
    assert audit =~ "wardrik.agent.defined"
  end

  test "sets and removes a trigger, and runs an agent", context do
    assert {0, "Set hourly. It runs next at " <> _next} =
             wardrik(context, [
               "trigger",
               "set",
               "triage",
               "hourly",
               "--every",
               "1h",
               "--prompt",
               "Look."
             ])

    assert {0, listed} = wardrik(context, ["trigger", "ls", "triage"])
    assert listed =~ ~r/hourly\s+every 1h\s+in (\d+m|1h)\s+Look\./

    assert {0, "Removed hourly.\n"} = wardrik(context, ["trigger", "rm", "triage", "hourly"])

    assert {0, "Set launch. It runs next at 2099-11-17T09:00:00-08:00.\n"} =
             wardrik(context, [
               "trigger",
               "set",
               "triage",
               "launch",
               "--at",
               "2099-11-17T09:00",
               "--timezone",
               "America/Los_Angeles",
               "--prompt",
               "Post it."
             ])

    assert {0, listed} = wardrik(context, ["trigger", "ls", "triage"])
    assert listed =~ ~r/launch\s+once at 2099-11-17T09:00 \(America\/Los_Angeles\)\s+in \S+/
    assert {0, "Stopped triage.\n"} = wardrik(context, ["agent", "stop", "triage"])
    assert {0, "Started triage.\n"} = wardrik(context, ["agent", "start", "triage"])
    assert {0, "It runs no tool calls now.\n"} = wardrik(context, ["agent", "calls", "triage"])
    assert {0, "No servers added.\n"} = wardrik(context, ["server", "ls"])
  end

  test "syncs a directory into an agent's files, and reads, writes and deletes one", context do
    skills = Path.join(context.root, "skills")
    triage_dir = Path.join(skills, "triage")
    git_dir = Path.join(skills, ".git")
    skill = Path.join(triage_dir, "SKILL.md")
    logo = Path.join(skills, "logo.png")
    head = Path.join(git_dir, "HEAD")
    File.mkdir_p!(triage_dir)
    File.mkdir_p!(git_dir)
    File.write!(skill, "---\nname: triage\n---\nLook first.\n")
    File.write!(logo, <<0xFF, 0xD8, 0xFF>>)
    File.write!(head, "ref: main\n")
    sync = ["agent", "files", "sync", "triage", skills, "--to", "skills"]

    assert {0, "Wrote 1, kept 0.\nLeft out logo.png: it isn't text.\n"} =
             wardrik(context, sync)

    assert {0, "Wrote 0, kept 1.\nLeft out logo.png: it isn't text.\n"} =
             wardrik(context, sync)

    assert {0, "---\nname: triage\n---\nLook first.\n"} =
             wardrik(context, ["agent", "files", "cat", "triage", "skills/triage/SKILL.md"])

    assert {0, "Wrote MEMORY.md.\n"} =
             wardrik(context, ["agent", "files", "put", "triage", "MEMORY.md"], "Likes tea.")

    assert {0, listed} = wardrik(context, ["agent", "files", "ls", "triage"])
    assert listed =~ ~r/^MEMORY.md\s+10\s/m
    assert listed =~ ~r/^skills\/triage\/SKILL.md\s+/m

    assert {0, only} = wardrik(context, ["agent", "files", "ls", "triage", "skills/**"])
    refute only =~ "MEMORY.md"

    assert {0, found} = wardrik(context, ["agent", "files", "search", "triage", "likes", "tea"])
    assert found =~ ~r/^MEMORY.md\s+1\s+\S+\s+Likes tea\.$/m
    refute found =~ "SKILL.md"

    assert {0, "Nothing matches.\n"} =
             wardrik(context, ["agent", "files", "search", "triage", "coffee", "--limit", "2"])

    deploy = Path.join(skills, "deploy.md")
    File.write!(skill, "---\nname: triage\n---\nLook twice.\n")
    File.write!(deploy, "Ship it.\n")
    put = ["agent", "files", "put", "triage", "skills/old.md", "-"]
    assert {0, "Wrote skills/old.md.\n"} = wardrik(context, put, "Old.")

    assert {0, json} = wardrik(context, sync ++ ["--delete", "--json"])

    assert JSON.decode!(json) == %{
             "written" => ["skills/deploy.md", "skills/triage/SKILL.md"],
             "kept" => [],
             "deleted" => ["skills/old.md"],
             "skipped" => ["logo.png"]
           }

    assert {0, "Deleted MEMORY.md.\n"} =
             wardrik(context, ["agent", "files", "rm", "triage", "MEMORY.md"])

    assert failing(context, ["agent", "files", "cat", "triage", "MEMORY.md"]) =~
             "has no file MEMORY.md"

    assert failing(context, ["agent", "files", "sync", "triage", "/no/such/dir"]) =~
             "isn't a directory"
  end
end
