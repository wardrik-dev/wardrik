defmodule Wardrik.Channel.StoredTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik, only: [unsealed: 2]

  alias Wardrik.Channel.Installation
  alias WardrikChannel.Channel

  setup context do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")
    name = :"wardrik #{context.test}"
    members = {Wardrik.Test.Channel.Members, members: %{}}
    chat = [installations: :stored, identities: members, test: self()]

    start_supervised!({WardrikStore, store})

    start_supervised!(
      {Wardrik,
       Wardrik.new(
         authorizer: {Wardrik.Test.Allow, []},
         resolver: {Wardrik.Test.Owned, name},
         name: name,
         store: store,
         vault_keys: [WardrikVault.generate_key()],
         channels: [chat: {Wardrik.Test.Channel.Chat, chat}]
       )}
    )

    {:ok, channel} = Wardrik.Test.Channel.fetch(name, "chat")
    %{channel: channel, wardrik: name}
  end

  test "keeps each workspace, with its token sealed", %{channel: channel, wardrik: wardrik} do
    assert Channel.installation(channel, "T1") == :error

    installation = %Installation{
      channel: "chat",
      workspace: "T1",
      owner: "acme",
      token: "xoxb-acme"
    }

    assert Channel.install(channel, installation) == :ok
    assert Channel.installation(channel, "T1") == {:ok, installation}
    assert unsealed(wardrik, {"acme", "chat:T1"}) == {:ok, "xoxb-acme"}

    assert Channel.uninstall(channel, "T1") == :ok
    assert Channel.installation(channel, "T1") == :error
    assert Channel.uninstall(channel, "T1") == :ok
  end

  test "finds the workspaces an owner holds, exactly, for a resolver", %{
    channel: channel,
    wardrik: wardrik
  } do
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

    assert Wardrik.Channels.owned(wardrik, channel: "chat", owner: "acme") == []

    org = installed.("T1", "acme")
    jon = installed.("T2", "acme/@jon")
    installed.("T3", "globex")

    assert Wardrik.Channels.owned(wardrik, channel: "chat", owner: "acme") == [org]
    assert Wardrik.Channels.owned(wardrik, channel: "chat", owner: "acme/@jon") == [jon]
    assert Wardrik.Channels.owned(wardrik, channel: "chat", owner: "acme/@maria") == []
    assert Wardrik.Channels.owned(wardrik, channel: "teams", owner: "acme") == []
  end

  test "finds no channel by a name the Wardrik doesn't run", %{wardrik: wardrik} do
    assert Wardrik.Test.Channel.fetch(wardrik, "teams") == :error
  end
end
