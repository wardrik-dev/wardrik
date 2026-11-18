defmodule WardrikDaemon.DoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import WardrikDaemon.Test

  alias WardrikDaemon.Doctor

  setup context do
    Req.Test.stub(__MODULE__, &slack/1)
    dirs(context)
  end

  defp slack(%Plug.Conn{path_info: ["mcp"]} = conn), do: mcp(conn, [%{name: "search_issues"}])

  defp slack(%Plug.Conn{path_info: ["api", method]} = conn) do
    case {method, Plug.Conn.get_req_header(conn, "authorization")} do
      {"auth.test", ["Bearer xoxb"]} ->
        Req.Test.json(conn, %{ok: true, user: "wardrik", team: "Acme"})

      {"apps.connections.open", _token} ->
        Req.Test.json(conn, %{ok: true, url: "wss://x"})

      _refused ->
        Req.Test.json(conn, %{ok: false, error: "invalid_auth"})
    end
  end

  # Answers as a Streamable HTTP server does: initialize as JSON, tools/list as an event stream.
  defp mcp(conn, tools) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case JSON.decode!(body) do
      %{"method" => "initialize", "id" => id} ->
        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", "s1")
        |> Req.Test.json(%{jsonrpc: "2.0", id: id, result: %{protocolVersion: "2025-06-18"}})

      %{"method" => "notifications/initialized"} ->
        Plug.Conn.send_resp(conn, 202, "")

      %{"method" => "tools/list", "id" => id} ->
        ["s1"] = Plug.Conn.get_req_header(conn, "mcp-session-id")
        message = JSON.encode!(%{jsonrpc: "2.0", id: id, result: %{tools: tools}})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "event: message\ndata: #{message}\n\n")
    end
  end

  defp run(env), do: Doctor.run(env, req_options: [plug: {Req.Test, __MODULE__}])

  defp find_check(checks, name), do: for({status, ^name, found} <- checks, do: {status, found})

  defp listening do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    port
  end

  test "says which agents' saved states the running daemon can't read, and why", context do
    write(context, "config.yaml", "org: acme\n")
    dirs = WardrikDaemon.Dirs.new(context.env)
    token = WardrikDaemon.Dirs.data_home(dirs, "cli_token")

    token
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(token, JSON.encode!(%{id: "t1", secret: "s3cret", url: "http://daemon.test"}))

    why = "it names WardrikPolicy, which this release doesn't have"

    Req.Test.stub(__MODULE__, fn %Plug.Conn{path_info: ["v1", "agents"]} = conn ->
      case Plug.Conn.fetch_query_params(conn).query_params do
        %{"after" => "p2"} ->
          Req.Test.json(conn, %{
            "agents" => [
              %{
                "id" => "acme.old",
                "conversation" => "C1",
                "status" => "unreadable",
                "problem" => why,
                "pending" => 0
              }
            ],
            "next" => nil
          })

        _first ->
          Req.Test.json(conn, %{
            "agents" => [
              %{"id" => "acme.ok", "status" => "asleep", "pending" => 0},
              %{"id" => "acme.old", "status" => "unreadable", "problem" => why, "pending" => 0}
            ],
            "next" => "p2"
          })
      end
    end)

    assert find_check(run(context.env), "saved") == [
             {:fail,
              "acme.old can't start, as its saved state can't be read: #{why}. Define it again to start it over: `wardrik reload` does for agents in agents/."},
             {:fail,
              "acme.old's conversation C1 can't start, as its saved state can't be read: #{why}. Define it again to start it over: `wardrik reload` does for agents in agents/."}
           ]

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"agents" => [], "next" => nil}))
    assert find_check(run(context.env), "saved") == [{:ok, "every agent's saved state reads"}]

    File.rm!(token)
    assert find_check(run(context.env), "saved") == []
  end

  test "says each part reads where it does", context do
    env_file =
      write(context, "env", "# keys\nGITHUB_CLIENT_ID=Iv1\nexport SLACK_BOT_TOKEN=xoxb\n")

    File.chmod!(env_file, 0o600)

    write(context, "config.yaml", """
    org: acme
    defaults: {model: #{model()}}
    vault: {keys: ["#{Wardrik.Vault.generate_key()}"]}
    mcp:
      notes: {command: sh}
      github: {url: "http://127.0.0.1:#{listening()}/mcp"}
    oauth:
      providers:
        github: {issuer: https://github.com/login/oauth, client_id: "${GITHUB_CLIENT_ID}", client_secret: "${GITHUB_CLIENT_SECRET}", flow: device}
    channels:
      slack: {type: slack, token: "${SLACK_BOT_TOKEN}", app_token: xapp, members: {U1: user:acme/@maria}, domains: {acme.com: acme}}
    brave: {api_key: x}
    ssh: {}
    """)

    write(context, "policies/careful.yaml", "ask: [github/*]\n")

    write(
      context,
      "agents/triage.md",
      "---\ntools: [github/*]\npolicy: careful\nchannels: [slack]\n---\nTriage.\n"
    )

    checks = run(context.env)

    assert [{:ok, "#{env_file} sets 2 variables"}] == find_check(checks, "env")

    assert [{:ok, config}, {:warn, "ssh isn't supported here yet, so it's passed over"}] =
             find_check(checks, "config")

    assert config =~ "reads; the vault must hold GITHUB_CLIENT_SECRET"
    assert [{:ok, "1 key from config.yaml, which seals"}] = find_check(checks, "vault")
    assert [{:ok, "runs sh"}] = find_check(checks, "mcp notes")
    assert [{:ok, "lists 1 tool at 127.0.0.1:" <> _port}] = find_check(checks, "mcp github")

    assert [
             {:ok,
              "takes Slack's events over Socket Mode; posts as @wardrik in Acme; 1 member mapped to users, acme.com members to acme, others refused"}
           ] =
             find_check(checks, "channel slack")

    assert [{:ok, "signs people in with a device code" <> _}] = find_check(checks, "oauth")
    assert [{:ok, "1 agent file and 1 policy read"}] = find_check(checks, "agents")
    assert [{:ok, "web_search has a key"}] = find_check(checks, "brave")

    assert capture_io(fn -> assert Doctor.print(checks) == 0 end) =~
             ~r/ok    channel slack  takes/
  end

  test "says which servers list tools, which refuse, and which it can't list", context do
    port = listening()

    Req.Test.stub(__MODULE__, fn
      %Plug.Conn{path_info: ["refused"]} = conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{error: %{message: "This API key has no access"}})

      conn ->
        mcp(conn, [%{name: "a"}, %{name: "b"}])
    end)

    write(context, "config.yaml", """
    mcp:
      open: {url: "http://127.0.0.1:#{port}/mcp", headers: {x-api-key: k}}
      kept: {url: "http://127.0.0.1:#{port}/mcp", except: [b]}
      refused: {url: "http://127.0.0.1:#{port}/refused"}
      sealed: {url: "http://127.0.0.1:#{port}/mcp", headers: {x-api-key: "${SEALED_KEY}"}}
      github: {url: "http://127.0.0.1:#{port}/mcp", credential: github}
      routed: {credential: routed}
    """)

    checks = run(context.env)

    assert [{:ok, "lists 2 tools at 127.0.0.1:" <> _port}] = find_check(checks, "mcp open")

    assert [{:ok, kept}] = find_check(checks, "mcp kept")
    assert kept =~ ~r/^lists 2 tools at 127.0.0.1:\d+; only and except keep 1$/

    assert [{:fail, refused}] = find_check(checks, "mcp refused")
    assert refused =~ "but initialize gets 403: This API key has no access"

    assert [{:ok, sealed}] = find_check(checks, "mcp sealed")
    assert sealed =~ "the vault holds its headers"

    assert [{:ok, github}] = find_check(checks, "mcp github")
    assert github =~ "each user's account reaches it"

    assert [{:ok, routed}] = find_check(checks, "mcp routed")
    assert routed =~ "the credential routed gives each user's URL"
  end

  test "says whether the credential broker answers", context do
    write(context, "config.yaml", """
    broker: {url: "http://127.0.0.1:#{listening()}/credentials", secret: s, credentials: [gmail]}
    """)

    assert [{:ok, "answers gmail at 127.0.0.1:" <> _port}] =
             find_check(run(context.env), "broker")
  end

  test "says whether each harness runs and each checkout is a repository", context do
    repo =
      Path.join(
        context.env["HOME"] || System.tmp_dir!(),
        "repo-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)
    gitconfig = Path.join(repo, ".gitconfig-test")
    File.write!(gitconfig, "[user]\n\tname = Test\n\temail = test@example.com\n")
    git = [{"GIT_CONFIG_GLOBAL", gitconfig}, {"GIT_CONFIG_NOSYSTEM", "1"}]

    for args <- [["init", "-q"], ["commit", "-q", "--allow-empty", "-m", "First"]],
        do:
          {_output, 0} = System.cmd("git", ["-C", repo | args], env: git, stderr_to_stdout: true)

    write(context, "config.yaml", """
    harnesses:
      claude: {command: sh}
      codex: {command: no-such-acp-agent}
    checkouts:
      core: #{repo}
      gone: #{repo}-gone
      based: {path: #{repo}, base: release}
    """)

    checks = run(context.env)

    assert [{:ok, "runs sh"}] = find_check(checks, "harness claude")

    assert [{:fail, "runs no-such-acp-agent, which isn't on this machine's PATH"}] =
             find_check(checks, "harness codex")

    assert [{:ok, "#{repo} is a git repository; new work starts from HEAD"}] ==
             find_check(checks, "checkout core")

    assert [{:fail, "#{repo}-gone isn't a git repository with HEAD"}] ==
             find_check(checks, "checkout gone")

    assert [{:fail, "#{repo} isn't a git repository with release"}] ==
             find_check(checks, "checkout based")
  end

  test "says where everything is kept, and whether Postgres answers", context do
    write(context, "config.yaml", "org: acme\n")

    assert [{:ok, "keeps everything on this node's disk" <> _}] =
             find_check(run(context.env), "storage")

    write(
      context,
      "config.yaml",
      "storage: {postgres: {url: \"postgres://u:p@127.0.0.1:#{listening()}/w\"}}\n"
    )

    assert [{:ok, "keeps everything in Postgres at 127.0.0.1:" <> _}] =
             find_check(run(context.env), "storage")

    write(
      context,
      "config.yaml",
      "storage: {postgres: {url: \"postgres://u:p@127.0.0.1:1/w\"}}\n"
    )

    assert [{:fail, "Postgres at 127.0.0.1:1/w doesn't answer: " <> _}] =
             find_check(run(context.env), "storage")

    write(context, "config.yaml", s3("http://127.0.0.1:#{listening()}"))

    assert [{:ok, "keeps everything in the bucket wardrik at http://127.0.0.1:" <> _}] =
             find_check(run(context.env), "storage")

    write(context, "config.yaml", s3("http://127.0.0.1:1"))

    assert [{:fail, "the bucket wardrik at http://127.0.0.1:1 doesn't answer: " <> _}] =
             find_check(run(context.env), "storage")
  end

  defp s3(endpoint),
    do:
      "storage: {s3: {bucket: wardrik, endpoint: \"#{endpoint}\", access_key_id: k, secret_access_key: s}}\n"

  test "says what doesn't read, and why", context do
    env_file = write(context, "env", "A=1\nnot a variable\n")
    File.chmod!(env_file, 0o644)

    write(context, "config.yaml", """
    org: acme
    defaults: {model: #{model()}}
    vault: {keys: [short]}
    mcp:
      notes: {command: no-such-program-here}
      github: {url: "http://127.0.0.1:#{free_port()}/mcp"}
    oauth:
      providers:
        mail: {authorization_endpoint: https://mail.test/a, token_endpoint: https://mail.test/t, client_id: x}
    base_url: http://127.0.0.1:#{free_port()}
    channels:
      quiet: {type: slack, token: t, domains: {acme.com: acme}}
      open: {type: slack, token: t, signing_secret: s}
    """)

    write(context, "agents/broken.md", "---\ntools: [nope]\n---\n")
    write(context, "agents/odd.md", "---\ncolour: red\n---\n")
    write(context, "agents/far.md", "---\norg: globex\n---\n")
    write(context, "agents/lost.md", "---\nworkspace: {shared: {team: \"agent:ghost\"}}\n---\n")

    checks = run(context.env)

    assert [{:fail, "#{env_file} can be read by others; chmod 600 it"}] ==
             find_check(checks, "env")

    assert [{:fail, "a key from config.yaml isn't 32 bytes of base64"}] =
             find_check(checks, "vault")

    assert [{:warn, "config.yaml gives web_search no key." <> rest}] = find_check(checks, "brave")
    assert rest =~ "wardrik vault put BRAVE_API_KEY --for api_key"

    assert [{:fail, "runs no-such-program-here, which isn't on this machine's PATH"}] =
             find_check(checks, "mcp notes")

    assert [{:fail, "doesn't answer at 127.0.0.1:" <> _}] = find_check(checks, "mcp github")
    assert [{:fail, "takes nothing from Slack" <> _}] = find_check(checks, "channel quiet")

    assert [{:fail, ~s(Slack refused its token: "invalid_auth")}] =
             find_check(checks, "channel open")

    assert [{:fail, "http://127.0.0.1:" <> _}] = find_check(checks, "oauth")

    agents = find_check(checks, "agents")
    assert {:fail, "broken.md: There's no tool nope here."} in agents
    assert Enum.any?(agents, fn {:fail, why} -> why =~ "odd.md" end)
    assert Enum.any?(agents, fn {:fail, why} -> why =~ ~s(far.md: is in the org "globex") end)

    assert {:fail, "lost.md: workspace.shared.team: names no agent of acme, as agent:NAME"} in agents

    capture_io(fn -> assert Doctor.print(checks) > 0 end)

    File.chmod!(env_file, 0o600)

    assert [{:fail, "#{env_file} sets no variable on line 2"}] ==
             find_check(run(context.env), "env")
  end

  test "stops after a config that doesn't read, and says how the command did", context do
    write(context, "config.yaml", "nope: 1\n")
    assert [{:ok, "env", _none}, {:fail, "config", why}] = run(context.env)
    assert why =~ "unknown options [:nope], valid options are: [:org,"

    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn -> assert WardrikDaemon.CLI.main(["doctor"], env: context.env) == 1 end)
      end)

    assert stderr =~ "1 of the checks failed."
  end

  test "says where a policy doesn't read, and where the vault has no key yet", context do
    write(context, "config.yaml", "org: acme\n")
    write(context, "policies/empty.yaml", "")
    checks = run(context.env)

    assert [{:fail, "agents", why}] =
             Enum.filter(checks, &match?({_status, "agents", _found}, &1))

    assert why =~ "empty.yaml: is empty"
    assert [{:ok, "no key yet" <> _}] = find_check(checks, "vault")

    assert find_check(
             run(Map.put(context.env, "WARDRIK_VAULT_KEY", Wardrik.Vault.generate_key())),
             "vault"
           ) ==
             [{:ok, "1 key from WARDRIK_VAULT_KEY, which seals"}]
  end

  test "names the tools an older assistant.md leaves out", context do
    write(context, "config.yaml", "org: acme\ndefaults: {model: #{model()}}\n")

    write(
      context,
      "agents/assistant.md",
      "---\ntools: [self/*, agents/*, agent_create, files]\n---\nHi.\n"
    )

    assert [{:warn, found}] = find_check(run(context.env), "assistant")
    assert found =~ "doesn't give ops/agent.runs, ops/agent.timeline"
    assert found =~ "settings, help, web_search, run_lua"

    tools = Enum.join(WardrikDaemon.CLI.Init.assistant_tools(), ", ")
    write(context, "agents/assistant.md", "---\ntools: [#{tools}]\n---\nHi.\n")
    assert [{:ok, _found}] = find_check(run(context.env), "assistant")

    file = Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents/assistant.md")
    File.rm!(file)
    assert [] = find_check(run(context.env), "assistant")
  end
end
