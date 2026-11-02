defmodule WardrikDaemon.CLITest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO
  import WardrikDaemon.Test

  alias WardrikDaemon.CLI

  setup :set_mimic_global

  setup context do
    context = dirs(context)

    write(context, "config.yaml", """
    org: acme
    http: {port: #{free_port()}}
    defaults: {model: #{model()}, retries: {attempts: 0, on_exhausted: fail}}
    """)

    write(context, "policies/careful.yaml", "ask: [echo]\n")

    write(context, "agents/triage.md", """
    ---
    description: Triages.
    tools: [echo]
    policy: careful
    triggers:
      - {name: daily, every: "0 9 * * *", prompt: Go.}
    ---
    You watch the queue.
    """)

    context
  end

  defp wardrik(context, argv, input \\ "") do
    output =
      capture_io(input, fn -> send(self(), {:status, CLI.main(argv, env: context.env)}) end)

    assert_received {:status, status}
    {status, output}
  end

  defp failing(context, argv) do
    run = fn -> send(self(), {:status, CLI.main(argv, env: context.env)}) end
    stderr = capture_io(:stderr, fn -> capture_io("", run) end)

    assert_received {:status, 1}
    stderr
  end

  # Stands in for bin/wardrik, writing each command it's given to the log.
  defp script(context) do
    script = Path.join(context.root, "wardrik")
    log = Path.join(context.root, "script.log")
    File.mkdir_p!(context.root)
    File.write!(script, "#!/bin/sh\necho \"$*\" >> '#{log}'\n")
    File.chmod!(script, 0o755)
    {put_in(context.env["WARDRIK_SCRIPT"], script), log}
  end

  @init ~w(init --provider anthropic --no-ask)

  test "writes a first config and agent, keeps what's there, and starts the daemon", context do
    {context, log} = script(context)
    File.rm!(Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml"))
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")

    assert {0, output} = wardrik(context, @init ++ ~w(--org globex --model claude-sonnet-5))
    assert output =~ "ANTHROPIC_API_KEY is read from " <> context.env["WARDRIK_CONFIG_DIR"]
    assert output =~ "Wrote " <> Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")
    assert output =~ "agents/assistant.md"
    assert output =~ "Kept  " <> Path.join(context.env["WARDRIK_CONFIG_DIR"], "env")
    assert output =~ ~s(wardrik ask assistant "Tell me when)
    assert File.read!(log) == "start\n"

    assert File.read!(Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")) =~
             "org: globex\n\ndefaults:\n  model: anthropic:claude-sonnet-5\n"

    assert {0, again} = wardrik(context, @init ++ ~w(--no-service))
    assert again =~ "Kept"
    refute again =~ "names no default model"

    write(context, "config.yaml", "org: globex\n")
    assert {0, again} = wardrik(context, @init ++ ~w(--no-service))
    assert again =~ "config.yaml names no default model, so the front door has none. Add it:"
    assert File.read!(log) == "start\nstart\nstart\n"
  end

  test "names the flag a question needs where no one can answer it", context do
    {context, _log} = script(context)

    assert failing(context, ["init"]) =~
             "no terminal to ask which model provider. Pass --provider"

    assert failing(context, ~w(init --provider anthropic)) =~
             "no terminal to ask for ANTHROPIC_API_KEY. Set it, or pass --key-from-env VAR."

    assert failing(context, ~w(init --provider nobody)) =~
             "--provider nobody isn't a model provider"

    assert failing(context, ~w(init --provider anthropic --model no-such)) =~
             "anthropic has no model no-such. Its newest are claude-"

    assert failing(context, ~w(init --provider anthropic --key-from-env NOPE)) =~
             "--key-from-env NOPE names a variable this environment doesn't set."

    refute File.exists?(Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents/assistant.md"))
  end

  test "gives the front door web_search where a Brave key is set", context do
    {context, _log} = script(context)
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")
    config = Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")
    assistant = Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents/assistant.md")
    File.rm!(config)

    assert {0, _wrote} = wardrik(context, @init)
    assert File.read!(config) =~ "# brave:\n#   api_key: ${BRAVE_API_KEY}"
    assert File.read!(assistant) =~ "tools: [self/*, agents/*, files, run_lua]"

    File.rm!(config)
    File.rm!(assistant)
    context = put_in(context.env["BRAVE_API_KEY"], "bk")

    assert {0, _wrote} = wardrik(context, @init)
    assert File.read!(config) =~ ~r/^brave:\n  api_key: \$\{BRAVE_API_KEY\}/m
    assert File.read!(assistant) =~ "tools: [self/*, agents/*, files, web_search, run_lua]"
  end

  test "writes a front door that the daemon defines", context do
    {context, _log} = script(context)
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")
    assert {0, _wrote} = wardrik(context, @init)
    context = start_daemon(context)

    assert {:ok, %Wardrik.Definition{} = front, []} =
             Wardrik.Agent.definition(context.admin, "acme/assistant")

    assert front.tools == ["self/*", "agents/*", "files", "run_lua"]
    assert front.context == ["MEMORY.md"]
    assert front.idle_timeout == :infinity
    assert front.policy == %{"budget" => %{"tokens" => 2_000_000, "per" => "day"}}
    assert front.instructions =~ "You are Wardrik, the one place the people of this org come"
    assert front.instructions =~ "# Playbook"
  end

  test "says how to start the daemon where it hasn't", context do
    assert failing(context, ["ls"]) =~ "Start it with `wardrik start`"
    assert failing(context, ["nope"]) =~ "nope isn't a command"
    assert failing(context, ["ls", "--colour", "red"]) =~ "--colour isn't an option"
    assert {0, help} = wardrik(context, ["help"])
    assert help =~ "Usage: wardrik COMMAND"
    assert help =~ ~r/Agents\n  agent ls \[QUERY\]\s+list the agents/
    assert help =~ "Shortcuts: ls for agent ls"

    assert {0, agents} = wardrik(context, ["agent"])
    assert agents =~ "Usage: wardrik agent COMMAND"
    refute agents =~ "token create"

    assert {0, asking} = wardrik(context, ["agent", "ask", "--help"])
    assert asking =~ "Usage: wardrik agent ask AGENT MESSAGE [--no-wait]"
    assert asking =~ "Also: wardrik ask"
    assert {0, ^asking} = wardrik(context, ["help", "agent", "ask"])

    assert failing(context, ["agent", "show"]) =~ "Usage: wardrik agent show AGENT"
    assert failing(context, ["start"]) =~ "script runs that itself"
  end

  test "writes completion for bash, zsh and fish", context do
    assert {0, bash} = wardrik(context, ["completion", "bash"])
    assert bash =~ ~s("agent ls"|"agent ls "*|"ls"|"ls "*\) words="--all --json --help")
    assert bash =~ "complete -F _wardrik wardrik rik"

    assert {0, "autoload -U +X bashcompinit && bashcompinit\n" <> _rest} =
             wardrik(context, ["completion", "zsh"])

    assert {0, fish} = wardrik(context, ["completion", "fish"])
    assert fish =~ ~s(complete -c rik -n 'test (__wardrik_words\) = "+agent"' -a cancel -d)
    assert fish =~ ~s(-l no-wait)

    assert failing(context, ["completion", "tcsh"]) =~ "bash, zsh or fish"
    assert failing(context, ["pid"]) =~ "script runs that itself"
  end

  describe "with the daemon running" do
    setup :start_daemon

    test "lists and shows agents, and their triggers", context do
      assert {0, listed} = wardrik(context, ["ls"])
      assert listed =~ ~r/acme\/triage\s+idle/

      assert {0, shown} = wardrik(context, ["agent", "show", "triage"])
      assert shown =~ ~r/description\s+Triages\./
      assert shown =~ ~r/policy\s+careful/

      assert {0, triggers} = wardrik(context, ["trigger", "ls", "acme/triage"])
      assert triggers =~ ~r/daily\s+every 0 9 \* \* \*\s+in \d+[hm][\dhm ]*\s+Go\./

      assert {0, json} = wardrik(context, ["ls", "--json"])
      assert %{"agents" => [%{"id" => "acme/triage"}]} = JSON.decode!(json)

      {:ok, _agent} = Wardrik.Agent.define(context.admin, "acme/@jon/mine", model: model())

      ids = fn query ->
        context
        |> wardrik(["ls", "--json" | query])
        |> elem(1)
        |> JSON.decode!()
        |> Map.fetch!("agents")
        |> Enum.map(& &1["id"])
      end

      assert ids.(["org:acme"]) == ["acme/@jon/mine", "acme/triage"]
      assert ids.(["user:jon"]) == ["acme/@jon/mine"]
      assert ids.(["name:triage", "status:idle"]) == ["acme/triage"]
      assert ids.(["tri"]) == ["acme/triage"]
      assert ids.(["org:globex"]) == []
      assert ids.(["attention"]) == []
      assert {0, "No agents match.\n"} = wardrik(context, ["ls", "node:nowhere"])

      assert failing(context, ["agent", "show", "nobody"]) =~ "acme/nobody"
      assert failing(context, ["agent", "rm", "triage"]) =~ "declared by a file"
    end

    test "says how each kind of trigger runs, and what it asks", context do
      long = String.duplicate("Read the news. ", 6)

      write(context, "agents/watcher.md", """
      ---
      tools: [files]
      triggers:
        - {name: morning, every: "0 9 * * *", timezone: America/Los_Angeles, prompt_file: CHECKLIST.md}
        - {name: news, every: 1h, feed: https://example.com/feed.xml, prompt: "#{long}"}
        - {name: pushed, webhook: {secret: "${HOOK_SECRET}"}, prompt: Look.}
      ---
      Watch.
      """)

      assert {0, _reloaded} = wardrik(context, ["reload"])
      assert {0, listed} = wardrik(context, ["trigger", "ls", "watcher"])

      assert listed =~
               ~r/morning\s+every 0 9 \* \* \* \(America\/Los_Angeles\)\s+in \S+( \S+)?\s+follows CHECKLIST\.md/

      assert listed =~ ~r/news\s+every 1h\s+in \d+m\s+Read the news\./
      assert listed =~ "…"
      assert listed =~ ~r/pushed\s+on a webhook\s+Look\./
    end

    test "asks an agent, and says what it waits on", context do
      answers([%{answer("Two cases.") | usage: %{input_tokens: 1_200, output_tokens: 34}}])
      assert {0, "Two cases.\n"} = wardrik(context, ["ask", "triage", "How", "many?"])
      assert {0, listed} = wardrik(context, ["ls"])
      assert listed =~ ~r/acme\/triage\s+idle\s+in \S+( \S+)?\s+1\.2k tokens/
      assert {0, history} = wardrik(context, ["agent", "history", "triage"])
      assert history =~ "› How many?"
      assert history =~ "Two cases."

      answers([calling("call_1", "echo", %{"text" => "hi"}), answer("Done.")])
      assert {0, waiting} = wardrik(context, ["ask", "triage", "Echo hi"])
      assert waiting =~ ~s(→ echo {"text":"hi"})
      assert waiting =~ "Waiting on a person for 1 call:"
      assert waiting =~ "? echo  call_1"
      assert waiting =~ "wardrik approval approve acme/triage ID"

      assert {0, parked} = wardrik(context, ["approval", "ls"])
      assert parked =~ ~r/acme\/triage\s+call_1\s+echo/

      assert {0, "Approved call_1.\n"} =
               wardrik(context, ["approval", "approve", "triage", "call_1", "--note", "Go."])

      assert failing(context, ["approval", "deny", "triage", "call_1"]) =~
               "doesn't wait on call_1"
    end

    test "seals the key it's given, reads the front door's file, and asks it", context do
      answers([answer("I turn what you ask for into work that runs.")])
      context = put_in(context.env["MY_KEY"], "sk-given")

      assert {0, output} = wardrik(context, ~w(init --provider anthropic --key-from-env MY_KEY))
      assert output =~ "The daemon runs, and read what init wrote."
      assert output =~ "Sealed ANTHROPIC_API_KEY."
      assert output =~ "Asking the front door: In two short sentences"
      assert output =~ "I turn what you ask for into work that runs."
      assert {0, secrets} = wardrik(context, ["vault", "ls"])
      assert secrets =~ "ANTHROPIC_API_KEY"
    end

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
      Mimic.stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
        {:error, %RuntimeError{message: "down"}}
      end)

      assert failing(context, ["ask", "triage", "Hi"]) =~ "The turn failed."
    end

    test "seals, lists and removes secrets", context do
      assert {0, "Sealed GITHUB_TOKEN.\n"} =
               wardrik(context, ~w(vault put GITHUB_TOKEN --org acme --for header), "ghp_1\n")

      vault = context.wardrik |> Wardrik.Instance.fetch!() |> Wardrik.vault()

      assert {:ok, "ghp_1"} =
               WardrikVault.fetch(vault, %WardrikCore.Principal{id: "acme"}, "GITHUB_TOKEN")

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
      assert reloaded =~ "! Wardrik didn't define acme/broken."
      assert reloaded =~ "broken.md: "

      assert {0, status} = wardrik(context, ["status"])
      assert status =~ "Wardrik runs at http://127.0.0.1:"
      assert {0, audit} = wardrik(context, ["audit"])
      assert audit =~ "wardrik.agent.defined"
    end

    test "sets and removes a trigger, and runs an agent", context do
      assert {0, "Set hourly.\n"} =
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
      assert listed =~ ~r/hourly\s+every 1h\s+in \d+m\s+Look\./

      assert {0, "Removed hourly.\n"} = wardrik(context, ["trigger", "rm", "triage", "hourly"])
      assert {0, "Stopped acme/triage.\n"} = wardrik(context, ["agent", "stop", "triage"])
      assert {0, "Started acme/triage.\n"} = wardrik(context, ["agent", "start", "triage"])
      assert {0, "It runs no tool calls now.\n"} = wardrik(context, ["agent", "calls", "triage"])
      assert {0, "No servers added.\n"} = wardrik(context, ["server", "ls"])
    end

    test "adds and removes an MCP server, and says which accounts are offered", context do
      assert {0, "Added docs. Agents reach it as docs/*.\n"} =
               wardrik(context, ["server", "add", "docs", "--url", "http://127.0.0.1:1/mcp"])

      assert {0, listed} = wardrik(context, ["server", "ls"])
      assert listed =~ ~r/docs\s+http:\/\/127.0.0.1:1\/mcp\s+none/
      assert {0, "Removed docs.\n"} = wardrik(context, ["server", "rm", "docs"])

      assert {0, "Added wiki. Agents reach it as wiki/*.\n"} =
               wardrik(context, [
                 "server",
                 "add",
                 "wiki",
                 "--url",
                 "http://127.0.0.1:1/mcp",
                 "--only",
                 "read,search"
               ])

      assert {0, "Removed wiki.\n"} = wardrik(context, ["server", "rm", "wiki"])

      assert failing(context, ["server", "add", "docs"]) =~ "Give the server's --url"

      assert failing(context, [
               "server",
               "add",
               "crm",
               "--url",
               "http://127.0.0.1:1/mcp",
               "--secret",
               "CRM"
             ]) =~ "holds no secret CRM"

      assert {0, "No accounts are offered.\n"} = wardrik(context, ["connection", "ls"])
      assert failing(context, ["connection", "connect", "github"]) =~ "no account github"
      assert failing(context, ["connection", "disconnect", "github", "--user", "jon"]) =~ "github"
    end

    test "sends without following, and stops, clears and removes agents", context do
      answers([answer("Later.")])

      assert {0, "Sent it to acme/triage.\n"} =
               wardrik(context, ["ask", "triage", "Hi", "--no-wait"])

      assert {0, "Stopped the turn of acme/triage.\n"} =
               wardrik(context, ["agent", "cancel", "triage"])

      assert {0, "No agent was taking a turn.\n"} =
               wardrik(context, ["agent", "cancel", "triage", "acme/triage/C1"])

      assert {0, "No agent was taking a turn.\n"} = wardrik(context, ["agent", "cancel", "--all"])
      assert failing(context, ["agent", "cancel", "triage", "--all"]) =~ "--all alone"
      assert failing(context, ["agent", "cancel"]) =~ "--all alone"

      assert {0, "Cleared acme/triage.\n"} = wardrik(context, ["agent", "clear", "triage"])
      assert failing(context, ["agent", "kill", "triage", "nope"]) =~ "nope"
      assert failing(context, ["agent", "move", "triage", "wardrik@nowhere"]) =~ "wardrik@nowhere"

      {:ok, _agent} = Wardrik.Agent.define(context.admin, "acme/temp", model: model())
      assert {0, "Removed acme/temp.\n"} = wardrik(context, ["agent", "rm", "temp"])
    end

    test "reaches an agent's conversation, as a chat thread is", context do
      answers([answer("In the thread.")])
      assert {0, "In the thread.\n"} = wardrik(context, ["ask", "acme/triage/C1", "Hi"])
      assert {0, history} = wardrik(context, ["agent", "history", "acme/triage/C1"])
      assert history =~ "In the thread."
      assert {0, shown} = wardrik(context, ["agent", "show", "acme/triage/C1"])
      assert shown =~ ~r/agent\s+acme\/triage\/C1/
      assert {0, listed} = wardrik(context, ["ls"])
      assert listed =~ ~r/acme\/triage\s+idle\s+in \S+( \S+)?\s+1$/m
    end

    test "reaches another daemon by its URL and token", context do
      {:ok, %{url: url, secret: secret}} =
        WardrikDaemon.CLIToken.read(Path.join(context.env["WARDRIK_DATA_HOME"], "cli_token"))

      remote =
        Map.merge(context.env, %{
          "WARDRIK_URL" => url,
          "WARDRIK_TOKEN" => secret,
          "WARDRIK_DATA_HOME" => "/nowhere"
        })

      assert {0, listed} = wardrik(%{context | env: remote}, ["ls"])
      assert listed =~ "acme/triage"
    end
  end

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)
    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    Mimic.stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  defp answer(text), do: response(ReqLLM.Context.assistant(text))

  defp calling(id, name, args),
    do:
      response(
        ReqLLM.Context.assistant("",
          tool_calls: [ReqLLM.ToolCall.new(id, name, JSON.encode!(args))]
        )
      )

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
end
