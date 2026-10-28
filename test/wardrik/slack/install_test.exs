defmodule Wardrik.Slack.InstallTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.Slack

  alias WardrikChannel.Installation
  alias WardrikSlack.Install

  setup :set_mimic_global
  setup :start_wardrik

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
    {:ok, channel} = Wardrik.Test.Channel.fetch(context.wardrik, "slack")
    {:ok, url} = Install.url(channel, "globex", return_to: "/settings")

    assert url =~ "https://slack.com/oauth/v2/authorize?"
    assert url =~ "client_id=1.2"
    assert url =~ "chat%3Awrite"

    assert {:ok,
            %Installation{
              workspace: "T7",
              owner: "globex",
              token: "xoxb-globex",
              approvers: ["@maria"]
            }, "/settings"} =
             Install.installed(channel, "globex", %{"code" => "good", "state" => state(url)})

    assert {:ok, %Installation{owner: "globex"}} =
             WardrikChannel.Channel.installation(channel, "T7")

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
    assert WardrikChannel.Channel.installation(channel, "T7") == :error
  end

  test "is refused for a channel added with its token alone", context do
    {:ok, channel} = Wardrik.Test.Channel.fetch(context.wardrik, "slack")
    assert {:error, "slack is added with its token alone" <> _} = Install.url(channel, "acme")
    assert "users:read.email" in Install.scopes()
  end
end
