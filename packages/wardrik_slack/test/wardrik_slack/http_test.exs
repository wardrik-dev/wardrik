defmodule WardrikSlack.HTTPTest do
  use ExUnit.Case, async: false

  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Response

  @secret "8f742231b10e8888abcd99yyyzzz85a5"
  @req_options [plug: {Req.Test, WardrikSlack.Stub}]

  setup do
    start_supervised!({Task.Supervisor, name: WardrikChannel.tasks()})

    installations = %WardrikSlack.Test.Installations{
      agent: start_supervised!({Agent, fn -> %{} end})
    }

    test = self()

    Req.Test.stub(WardrikSlack.Stub, fn conn ->
      send(test, {:slack, conn.request_path})
      Req.Test.json(conn, %{ok: true, user_id: "UBOT"})
    end)

    %{"slack" => channel} =
      WardrikChannel.channels(
        [
          channels: [slack: {WardrikSlack, signing_secret: @secret, req_options: @req_options}],
          installations: installations
        ],
        host: Wardrik.Host.new(store: Wardrik.Test.store())
      )

    %{channel: channel, installations: installations}
  end

  defp signed(path, body, opts \\ []) do
    at = Keyword.get(opts, :at, System.os_time(:second))

    signature =
      "v0=" <>
        Base.encode16(
          :crypto.mac(:hmac, :sha256, Keyword.get(opts, :secret, @secret), "v0:#{at}:#{body}"),
          case: :lower
        )

    %{
      method: "POST",
      path: path,
      headers: [
        {"x-slack-request-timestamp", to_string(at)},
        {"x-slack-signature", signature}
      ],
      body: body
    }
  end

  defp install(installations, workspace) do
    :ok =
      Installations.put(installations, %Installation{
        channel: "slack",
        workspace: workspace,
        owner: Wardrik.Resource.parse!("acme"),
        token: "xoxb-" <> workspace
      })
  end

  test "answers Slack's check of its Request URL with what it asked", %{channel: channel} do
    body = JSON.encode!(%{type: "url_verification", challenge: "3eZbrw1aB"})

    assert %Response{status: 200, body: answer} =
             WardrikChannel.request(channel, signed(["events"], body))

    assert JSON.decode!(answer) == %{"challenge" => "3eZbrw1aB"}
  end

  test "refuses what Slack did not sign, or signed too long ago", %{channel: channel} do
    body = JSON.encode!(%{type: "url_verification", challenge: "x"})

    for request <- [
          signed(["events"], body, secret: "another"),
          signed(["events"], body, at: System.os_time(:second) - 301),
          %{signed(["events"], body) | headers: []},
          %{signed(["events"], body) | body: body <> " "}
        ] do
      assert %Response{status: 401} = WardrikChannel.request(channel, request)
    end
  end

  test "takes nothing over HTTP without a signing secret, nor anywhere Slack sends nothing",
       %{channel: channel} do
    unsigned = %{channel | options: []}
    assert %Response{status: 404} = WardrikChannel.request(unsigned, signed(["events"], "{}"))
    assert %Response{status: 404} = WardrikChannel.request(channel, signed(["other"], "{}"))
    assert %Response{status: 400} = WardrikChannel.request(channel, signed(["actions"], "a=1"))
  end

  test "forgets a workspace's installation as the app is taken out of it",
       %{channel: channel, installations: installations} do
    install(installations, "T1")
    install(installations, "T2")

    for type <- ["app_uninstalled", "tokens_revoked"], workspace <- ["T1"] do
      body = JSON.encode!(%{type: "event_callback", team_id: workspace, event: %{type: type}})
      assert %Response{status: 200} = WardrikChannel.request(channel, signed(["events"], body))
    end

    assert :error = Installations.fetch(installations, "slack", "T1")
    assert {:ok, _still} = Installations.fetch(installations, "slack", "T2")
  end

  # The bot each workspace posts as is kept for as long as the node runs, so
  # each test asks of a workspace of its own.
  defp workspace, do: "T#{System.unique_integer([:positive])}"

  test "acts on an event in the workspace it came from, and passes over one not installed",
       %{channel: channel, installations: installations} do
    team = workspace()
    install(installations, team)

    joined = fn team ->
      JSON.encode!(%{
        type: "event_callback",
        team_id: team,
        event: %{type: "reaction_added"}
      })
    end

    assert %Response{status: 200} =
             WardrikChannel.request(channel, signed(["events"], joined.(team)))

    assert_receive {:slack, "/api/auth.test"}

    assert %Response{status: 200} =
             WardrikChannel.request(channel, signed(["events"], joined.("T9")))

    refute_receive {:slack, _path}, 100
  end

  test "acts on a button press as Slack sends it, a payload in a form",
       %{channel: channel, installations: installations} do
    team = workspace()
    install(installations, team)
    payload = JSON.encode!(%{type: "block_actions", team: %{id: team}, actions: []})
    body = URI.encode_query(payload: payload)

    assert %Response{status: 200} = WardrikChannel.request(channel, signed(["actions"], body))
    assert_receive {:slack, "/api/auth.test"}
  end
end
