defmodule WardrikSlack.InstallTest do
  use ExUnit.Case, async: false

  alias Wardrik.Resource
  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Response

  @req_options [plug: {Req.Test, WardrikSlack.Stub}]

  setup do
    test = self()

    Req.Test.stub(WardrikSlack.Stub, fn conn ->
      send(test, {:slack, conn.request_path, URI.decode_query(Req.Test.raw_body(conn))})

      Req.Test.json(conn, %{
        ok: true,
        access_token: "xoxb-T7",
        bot_user_id: "UBOT7",
        team: %{id: "T7", name: "Acme"}
      })
    end)

    installations = %WardrikSlack.Test.Installations{
      agent: start_supervised!({Agent, fn -> %{} end})
    }

    %{"slack" => channel} =
      WardrikChannel.channels(
        [
          channels: [
            slack:
              {WardrikSlack, client_id: "1.2", client_secret: "shh", req_options: @req_options}
          ],
          installations: installations,
          approvers: [slack: %WardrikChannel.Approvers.Named{names: ["@maria"]}]
        ],
        host: Wardrik.Host.new(store: Wardrik.Test.store())
      )

    %{channel: channel, installations: installations, acme: Resource.parse!("acme")}
  end

  defp back(query), do: %{method: "GET", path: ["install"], query: query, headers: [], body: ""}

  defp state(url), do: URI.decode_query(URI.parse(url).query)["state"]

  test "sends someone to add the app, and installs it for the owner it was asked for, with the channel's approvers",
       %{channel: channel, installations: installations, acme: acme} do
    assert {:ok, url} = WardrikChannel.install_url(channel, acme, return_to: "/settings/slack")
    assert %URI{host: "slack.com", path: "/oauth/v2/authorize", query: query} = URI.parse(url)
    assert %{"client_id" => "1.2", "scope" => scope} = URI.decode_query(query)
    assert String.split(scope, ",") == WardrikSlack.Install.scopes()
    assert "chat:write.public" in WardrikSlack.Install.scopes()

    assert %Response{status: 302, headers: [{"location", "/settings/slack"}]} =
             WardrikChannel.install(channel, acme, back(%{"code" => "c1", "state" => state(url)}))

    assert_received {:slack, "/api/oauth.v2.access",
                     %{"client_id" => "1.2", "client_secret" => "shh", "code" => "c1"}}

    assert {:ok,
            %Installation{
              workspace: "T7",
              owner: ^acme,
              token: "xoxb-T7",
              approvers: %WardrikChannel.Approvers.Named{names: ["@maria"]}
            } = installed} = Installations.fetch(installations, "slack", "T7")

    assert {:ok, "UBOT7"} = WardrikSlack.bot(%{installed | token: "x"}, [])
  end

  test "says it is added where it was asked to go nowhere after", %{channel: channel, acme: acme} do
    {:ok, url} = WardrikChannel.install_url(channel, acme)

    assert %Response{status: 200, body: "slack is added" <> _} =
             WardrikChannel.install(channel, acme, back(%{"code" => "c1", "state" => state(url)}))
  end

  test "installs nothing for another owner, nor from a state it did not sign",
       %{channel: channel, installations: installations, acme: acme} do
    {:ok, url} = WardrikChannel.install_url(channel, acme)
    globex = Resource.parse!("globex")

    for {owner, state} <- [{globex, state(url)}, {acme, "forged.state"}, {acme, nil}] do
      assert %Response{status: 403} =
               WardrikChannel.install(channel, owner, back(%{"code" => "c1", "state" => state}))
    end

    refute_received {:slack, "/api/oauth.v2.access", _form}
    assert :error = Installations.fetch(installations, "slack", "T7")
  end

  test "says why where Slack sent no code back", %{channel: channel, acme: acme} do
    {:ok, url} = WardrikChannel.install_url(channel, acme)

    assert %Response{status: 400, body: "Slack did not add the app: access_denied" <> _} =
             WardrikChannel.install(
               channel,
               acme,
               back(%{"error" => "access_denied", "state" => state(url)})
             )
  end

  test "installs nothing in more workspaces without its client", %{channel: channel, acme: acme} do
    tokened = %{channel | options: []}

    assert {:error, 404, _why} =
             WardrikSlack.Install.url(acme, WardrikChannel.Channel.options(tokened))

    assert %Response{status: 404} = WardrikChannel.install(tokened, acme, back(%{}))
  end

  test "says why where the host keeps no more installations",
       %{channel: channel, acme: acme} do
    config = %{
      channel
      | context: %{channel.context | installations: Installations.Config.new([])}
    }

    {:ok, url} = WardrikChannel.install_url(config, acme)

    assert %Response{status: 409, body: "slack is installed from its token" <> _} =
             WardrikChannel.install(config, acme, back(%{"code" => "c1", "state" => state(url)}))
  end
end
