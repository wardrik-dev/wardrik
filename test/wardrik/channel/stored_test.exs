defmodule Wardrik.Channel.StoredTest do
  use ExUnit.Case, async: false

  alias Wardrik.Channel.Installation
  alias WardrikChannel.Channel

  setup context do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")
    name = :"wardrik #{context.test}"
    chat = [installations: :stored, approvers: ["@maria"], test: self()]

    start_supervised!({WardrikStore, store})

    start_supervised!(
      {Wardrik,
       Wardrik.new(
         name: name,
         store: store,
         keys: [WardrikVault.generate_key()],
         channels: [chat: {Wardrik.Test.Channel.Chat, chat}]
       )}
    )

    {:ok, channel} = Wardrik.Test.Channel.fetch(name, "chat")
    %{channel: channel, wardrik: name}
  end

  test "keeps each workspace, with its token sealed", %{channel: channel, wardrik: wardrik} do
    assert channel.approvers == ["@maria"]
    assert Channel.installation(channel, "T1") == :error

    installation = %Installation{
      channel: "chat",
      workspace: "T1",
      owner: "acme",
      token: "xoxb-acme",
      approvers: :anyone
    }

    assert Channel.install(channel, installation) == :ok
    assert Channel.installation(channel, "T1") == {:ok, installation}
    assert Wardrik.fetch_secret(wardrik, "acme", "chat:T1") == {:ok, "xoxb-acme"}

    assert Channel.uninstall(channel, "T1") == :ok
    assert Channel.installation(channel, "T1") == :error
    assert Channel.uninstall(channel, "T1") == :ok
  end

  test "finds the workspace nearest an agent's owner", %{channel: channel} do
    installed = fn workspace, owner ->
      installation = %Installation{
        channel: "chat",
        workspace: workspace,
        owner: owner,
        token: "xoxb-#{workspace}"
      }

      :ok = Channel.install(channel, installation)
      installation
    end

    assert Channel.nearest(channel, "acme/triage") == :error

    org = installed.("T1", "acme")
    jon = installed.("T2", "acme/@jon")
    installed.("T3", "globex")

    assert Channel.nearest(channel, "acme/triage") == {:ok, org}
    assert Channel.nearest(channel, "acme/@jon/digest") == {:ok, jon}
    assert Channel.nearest(channel, "acme/@maria/digest") == {:ok, org}
  end

  test "finds no channel by a name the Wardrik doesn't run", %{wardrik: wardrik} do
    assert Wardrik.Test.Channel.fetch(wardrik, "teams") == :error
  end
end
