defmodule WardrikDaemon.DoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import WardrikDaemon.Test

  alias WardrikDaemon.Doctor

  setup context do
    Req.Test.stub(__MODULE__, &slack/1)
    dirs(context)
  end

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

  defp run(env), do: Doctor.run(env, req_options: [plug: {Req.Test, __MODULE__}])

  defp found(checks, name), do: for({status, ^name, found} <- checks, do: {status, found})

  defp listening do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    port
  end

  test "says each part reads where it does", context do
    env_file =
      write(context, "env", "# keys\nGITHUB_CLIENT_ID=Iv1\nexport SLACK_BOT_TOKEN=xoxb\n")

    File.chmod!(env_file, 0o600)

    write(context, "config.yaml", """
    org: acme
    defaults: {model: #{model()}}
    vault: {keys: ["#{WardrikVault.generate_key()}"]}
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

    assert [{:ok, "#{env_file} sets 2 variables"}] == found(checks, "env")

    assert [{:ok, config}, {:warn, "ssh isn't supported here yet, so it's passed over"}] =
             found(checks, "config")

    assert config =~ "reads; the vault must hold GITHUB_CLIENT_SECRET"
    assert [{:ok, "1 key from config.yaml, which seals"}] = found(checks, "vault")
    assert [{:ok, "runs sh"}] = found(checks, "mcp notes")
    assert [{:ok, "answers at 127.0.0.1:" <> _port}] = found(checks, "mcp github")

    assert [
             {:ok,
              "takes Slack's events over Socket Mode; posts as @wardrik in Acme; 1 member mapped to users, acme.com members to acme, others refused"}
           ] =
             found(checks, "channel slack")

    assert [{:ok, "signs people in with a device code" <> _}] = found(checks, "oauth")
    assert [{:ok, "1 agent file and 1 policy read"}] = found(checks, "agents")
    assert [{:ok, "web_search has a key"}] = found(checks, "brave")

    assert capture_io(fn -> assert Doctor.print(checks) == 0 end) =~
             ~r/ok    channel slack  takes/
  end

  test "says where everything is kept, and whether Postgres answers", context do
    write(context, "config.yaml", "org: acme\n")

    assert [{:ok, "keeps everything on this node's disk" <> _}] =
             found(run(context.env), "storage")

    write(
      context,
      "config.yaml",
      "storage: {postgres: {url: \"postgres://u:p@127.0.0.1:#{listening()}/w\"}}\n"
    )

    assert [{:ok, "keeps everything in Postgres at 127.0.0.1:" <> _}] =
             found(run(context.env), "storage")

    write(
      context,
      "config.yaml",
      "storage: {postgres: {url: \"postgres://u:p@127.0.0.1:1/w\"}}\n"
    )

    assert [{:fail, "Postgres at 127.0.0.1:1/w doesn't answer: " <> _}] =
             found(run(context.env), "storage")

    write(context, "config.yaml", s3("http://127.0.0.1:#{listening()}"))

    assert [{:ok, "keeps everything in the bucket wardrik at http://127.0.0.1:" <> _}] =
             found(run(context.env), "storage")

    write(context, "config.yaml", s3("http://127.0.0.1:1"))

    assert [{:fail, "the bucket wardrik at http://127.0.0.1:1 doesn't answer: " <> _}] =
             found(run(context.env), "storage")
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

    assert [{:fail, "#{env_file} can be read by others; chmod 600 it"}] == found(checks, "env")
    assert [{:fail, "a key from config.yaml isn't 32 bytes of base64"}] = found(checks, "vault")
    assert [{:warn, "web_search has no key; give it brave.api_key"}] = found(checks, "brave")

    assert [{:fail, "runs no-such-program-here, which isn't on this machine's PATH"}] =
             found(checks, "mcp notes")

    assert [{:fail, "doesn't answer at 127.0.0.1:" <> _}] = found(checks, "mcp github")
    assert [{:fail, "takes nothing from Slack" <> _}] = found(checks, "channel quiet")

    assert [{:fail, ~s(Slack refused its token: "invalid_auth")}] = found(checks, "channel open")

    assert [{:fail, "http://127.0.0.1:" <> _}] = found(checks, "oauth")

    agents = found(checks, "agents")
    assert {:fail, "broken.md: There's no tool nope here."} in agents
    assert Enum.any?(agents, fn {:fail, why} -> why =~ "odd.md" end)
    assert Enum.any?(agents, fn {:fail, why} -> why =~ ~s(far.md: is in the org "globex") end)

    assert {:fail, "lost.md: workspace.shared.team: names no agent of acme, as agent:NAME"} in agents

    capture_io(fn -> assert Doctor.print(checks) > 0 end)

    File.chmod!(env_file, 0o600)

    assert [{:fail, "#{env_file} sets no variable on line 2"}] ==
             found(run(context.env), "env")
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
    assert [{:ok, "no key yet" <> _}] = found(checks, "vault")

    assert found(
             run(Map.put(context.env, "WARDRIK_VAULT_KEY", WardrikVault.generate_key())),
             "vault"
           ) ==
             [{:ok, "1 key from WARDRIK_VAULT_KEY, which seals"}]
  end
end
