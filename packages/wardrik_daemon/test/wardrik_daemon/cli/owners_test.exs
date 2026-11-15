defmodule WardrikDaemon.CLI.OwnersTest do
  use WardrikDaemon.CLICase, async: true

  setup :start_daemon

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
    assert failing(context, ["connection", "disconnect", "github"]) =~ "github"
    assert failing(context, ["connection", "ls", "--user", "jon"]) =~ "isn't an option"
  end

  test "adds, lists and removes an owner's OAuth apps", context do
    assert {0, "No OAuth apps.\n"} = wardrik(context, ["provider", "ls"])

    assert {0, "Added linear. People sign in to linear with it.\n"} =
             wardrik(context, [
               "provider",
               "add",
               "linear",
               "--authorization-endpoint",
               "https://linear.test/authorize",
               "--token-endpoint",
               "https://linear.test/token",
               "--client-id",
               "acme-linear",
               "--scope",
               "read",
               "--org",
               "acme"
             ])

    assert {0, listed} = wardrik(context, ["provider", "ls", "--org", "acme"])
    assert listed =~ ~r/linear\s+acme\s+https:\/\/linear.test\/authorize/

    assert {0, connections} = wardrik(context, ["connection", "ls"])
    refute connections =~ "linear"

    assert failing(context, [
             "provider",
             "add",
             "crm",
             "--issuer",
             "https://crm.test",
             "--client-id",
             "c",
             "--secret",
             "CRM"
           ]) =~
             "holds no secret CRM"

    assert {0, "Removed linear.\n"} =
             wardrik(context, ["provider", "rm", "linear", "--org", "acme"])

    assert {0, "No OAuth apps.\n"} = wardrik(context, ["provider", "ls", "--org", "acme"])
  end

  test "adds, lists and removes an owner's notify targets", context do
    assert {0, "No notify targets.\n"} = wardrik(context, ["notify", "ls"])

    assert {0, "Added ops. Agents route to it with notify: ops.\n"} =
             wardrik(context, ["notify", "add", "ops", "--url", "http://127.0.0.1:1/hook"])

    assert {0, listed} = wardrik(context, ["notify", "ls"])
    assert listed =~ ~r/ops\s+webhook\s+http:\/\/127.0.0.1:1\/hook/
    assert {0, "Removed ops.\n"} = wardrik(context, ["notify", "rm", "ops"])

    assert failing(context, ["notify", "add", "ops"]) =~ "Give the webhook's --url"

    assert failing(context, [
             "notify",
             "add",
             "signed",
             "--url",
             "http://127.0.0.1:1/hook",
             "--secret",
             "NOPE",
             "--org",
             "acme"
           ]) =~ "acme holds no secret NOPE"
  end

  test "makes, lists and revokes tokens, showing a secret once", context do
    assert {0, made} =
             wardrik(context, [
               "token",
               "create",
               "laptop",
               "--subject",
               "user:acme/@ana",
               "--groups",
               "eng,ops",
               "--expires",
               "12h"
             ])

    assert [said, secret] = String.split(made, "\n", trim: true)

    assert [_whole, id] =
             Regex.run(~r{^Made (\w+) for user:acme/@ana\. It's shown once:$}, said)

    assert "wdk_" <> _rest = secret

    assert {0, listed} = wardrik(context, ["token", "ls"])
    assert listed =~ ~r{#{id}\s+laptop\s+user:acme/@ana\s+eng,ops}
    refute listed =~ secret

    assert wardrik(context, ["token", "revoke", id]) == {0, "Revoked #{id}.\n"}
    assert {0, listed} = wardrik(context, ["token", "ls"])
    refute listed =~ id

    assert failing(context, ["token", "create", "x"]) =~ "Give the token's --subject"

    assert failing(context, [
             "token",
             "create",
             "x",
             "--subject",
             "user:acme/@a",
             "--expires",
             "1y"
           ]) =~
             "--expires takes a time"

    assert failing(context, ["token", "create", "x", "--subject", "group:eng"]) =~ "subject"

    assert failing(context, ~w(token create x --subject user:ana)) =~
             "expected a user, as user:acme/@ana"

    # An agent is named as other commands name it, and its token acts as its ID.
    triage = id(context, "acme", "triage")
    assert {0, made} = wardrik(context, ~w(token create bot --subject agent:triage))
    assert made =~ "for agent:triage."

    assert [%{subject: subject}] =
             for(
               %{name: "bot"} = token <- WardrikDaemon.Tokens.list(context.daemon_store),
               do: token
             )

    assert subject == "agent:" <> triage
    assert {0, listed} = wardrik(context, ["token", "ls"])
    assert listed =~ ~r/bot\s+agent:triage\s/
    assert failing(context, ~w(token create bot --subject agent:nope)) =~ "no agent nope"
  end

  test "sends without following, and stops, clears and removes agents", context do
    test = self()

    # The turn is still in its model call as it's stopped. A turn stopped as its model call
    # starts can leave the agent shown as running.
    answers(context, [
      fn _request ->
        send(test, :asked)
        receive do: (:never -> nil)
      end
    ])

    assert {0, "Sent it to triage.\n"} =
             wardrik(context, ["ask", "triage", "Hi", "--no-wait"])

    assert_receive :asked, 5_000

    assert {0, "Stopped the turn of triage.\n"} =
             wardrik(context, ["agent", "cancel", "triage"])

    assert {0, "No agent was taking a turn.\n"} =
             wardrik(context, ["agent", "cancel", "triage", "acme/triage"])

    assert {0, "Stopped the turn of triage.\n"} =
             wardrik(context, ["agent", "cancel", "triage", "--conversation", "C1"])

    assert failing(context, ["agent", "cancel", "--all", "--conversation", "C1"]) =~
             "--all alone"

    assert {0, "No agent was taking a turn.\n"} = wardrik(context, ["agent", "cancel", "--all"])
    assert failing(context, ["agent", "cancel", "triage", "--all"]) =~ "--all alone"
    assert failing(context, ["agent", "cancel"]) =~ "--all alone"

    idle(context, id(context, "acme", "triage"))
    assert {0, "Cleared triage.\n"} = wardrik(context, ["agent", "clear", "triage"])
    assert failing(context, ["agent", "kill", "triage", "nope"]) =~ "nope"
    assert failing(context, ["agent", "move", "triage", "wardrik@nowhere"]) =~ "wardrik@nowhere"

    agent(context, "acme", "temp")
    assert {0, "Removed temp.\n"} = wardrik(context, ["agent", "rm", "temp"])
  end

  test "reaches an agent's conversation, as a chat thread is", context do
    answers(context, [answer("In the thread.")])
    thread = ["--conversation", "C1"]
    assert {0, "In the thread.\n"} = wardrik(context, ["ask", "triage", "Hi" | thread])
    assert {0, history} = wardrik(context, ["agent", "history", "triage" | thread])
    assert history =~ "In the thread."
    assert {0, own} = wardrik(context, ["agent", "history", "triage"])
    refute own =~ "In the thread."
    assert {0, shown} = wardrik(context, ["agent", "show", "triage" | thread])
    assert shown =~ ~r/agent\s+triage/
    assert shown =~ ~r/conversation\s+C1/
    assert {0, listed} = wardrik(context, ["ls"])
    assert listed =~ ~r/^triage\s+idle\s+in \S+( \S+)?\s+1$/m
    assert {0, listed} = wardrik(context, ["ls", "--all"])
    assert listed =~ ~r/^triage\s+idle\s+.*\s+C1$/m
  end

  test "reaches another daemon by its URL and token", context do
    path = Path.join(context.env["WARDRIK_DATA_HOME"], "cli_token")
    {:ok, %{url: url, secret: secret}} = WardrikDaemon.CLIToken.read(path)

    remote =
      Map.merge(context.env, %{
        "WARDRIK_URL" => url,
        "WARDRIK_TOKEN" => secret,
        "WARDRIK_DATA_HOME" => "/nowhere"
      })

    assert {0, listed} = wardrik(%{context | env: remote}, ["ls"])
    assert listed =~ ~r/^triage\s+idle/m
  end
end
