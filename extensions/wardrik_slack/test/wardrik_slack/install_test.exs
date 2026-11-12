defmodule WardrikSlack.InstallTest do
  use ExUnit.Case, async: false

  import WardrikSlack.Test

  alias Wardrik.Channel.Installation
  alias Wardrik.Chat
  alias WardrikSlack.Install

  setup :start_slack

  defp state(url),
    do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

  @tag slack: [
         token: nil,
         installations: :stored,
         client_id: "1.2",
         client_secret: "c13nt",
         redirect_uri: "https://myapp.example.com/slack/installed"
       ]
  test "adds the app to a workspace for the owner the link was made for", context do
    channel = context.channel
    {:ok, url} = Install.url(channel, "globex", return_to: "/settings")

    assert url =~ "https://slack.com/oauth/v2/authorize?"
    assert url =~ "client_id=1.2"
    assert url =~ "chat%3Awrite"

    assert {:ok,
            %Installation{
              workspace: "T7",
              name: "Globex",
              owner: "globex",
              token: "xoxb-globex"
            }, "/settings"} =
             Install.installed(channel, "globex", %{"code" => "good", "state" => state(url)})

    assert {:ok, %Installation{owner: "globex"}} =
             Chat.Channel.installation(channel, "T7")

    assert {:error, "This was started by someone else" <> _} =
             Install.installed(channel, "acme", %{"code" => "good", "state" => state(url)})

    assert {:error, "Slack didn't add the app: access_denied" <> _} =
             Install.installed(channel, "globex", %{
               "error" => "access_denied",
               "state" => state(url)
             })

    assert {:error, "Slack sent no code back" <> _} =
             Install.installed(channel, "globex", %{"state" => state(url)})

    assert {:error, "Slack didn't give the app its token" <> _} =
             Install.installed(channel, "globex", %{"code" => "bad", "state" => state(url)})

    assert {:error, "This was started" <> _} =
             Install.installed(channel, "globex", %{"code" => "good"})

    assert {:error, "This was started" <> _} =
             Install.installed(channel, "globex", %{"code" => "good", "state" => "x.y"})

    callback = %{type: "event_callback", team_id: "T7", event: %{type: "tokens_revoked"}}
    deliver(context, "events", JSON.encode!(callback))
    assert Chat.Channel.installation(channel, "T7") == :error
  end

  @tag slack: [
         token: nil,
         installations: :stored,
         client_id: "1.2",
         client_secret: "c13nt",
         redirect_uri: "https://myapp.example.com/slack/installed"
       ]
  test "is added and taken out as a channel adapter is", context do
    channel = context.channel

    {:ok, url} =
      WardrikSlack.install_url(
        %Wardrik.Chat.Install{owner: "globex", return_to: "/settings"},
        channel
      )

    assert {:ok, %Installation{workspace: "T7", name: "Globex"}, "/settings"} =
             WardrikSlack.installed(
               %Wardrik.Chat.Install{
                 owner: "globex",
                 query: %{"code" => "good", "state" => state(url)}
               },
               channel
             )

    assert WardrikSlack.uninstall("T7", channel) == :ok

    assert_received {:slack, "apps.uninstall",
                     %{"client_id" => "1.2", "client_secret" => "c13nt"}}

    assert Chat.Channel.installation(channel, "T7") == :error

    assert WardrikSlack.uninstall("T7", channel) == :ok
  end

  test "is refused for a channel added with its token alone", context do
    channel = context.channel
    assert {:error, "slack is added with its token alone" <> _} = Install.url(channel, "acme")
    assert "users:read" in Install.scopes()
    assert "users:read.email" in Install.scopes()
  end
end
