defmodule WardrikChannelTest do
  use ExUnit.Case, async: true

  alias Wardrik.Resource
  alias WardrikChannel.Channel
  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Outbound
  alias WardrikChannel.Response
  alias WardrikNotify.Notice

  defp installation,
    do: %Installation{
      channel: "named",
      workspace: "T1",
      owner: Resource.parse!("*"),
      token: "token"
    }

  defp host, do: Wardrik.Host.new(store: Wardrik.Test.store())

  defp notice,
    do: %Notice{
      agent: Wardrik.AgentID.parse!("acme/triage"),
      kind: :failed,
      at: DateTime.utc_now()
    }

  describe "attach/2" do
    test "has the host serve its channels' requests, and run them" do
      settings = [
        channels: [one: {WardrikChannel.Test.Adapter, test: self()}],
        installations: Installations.Config.new([])
      ]

      host = WardrikChannel.attach(host(), settings)

      assert [{["v1", "channels"], {WardrikChannel.Requests, routed}}] = Wardrik.Host.routes(host)
      assert routed[:channels] == settings[:channels]

      assert [
               {WardrikChannel.Replies, settings: kept},
               {WardrikChannel.Supervisor, settings: kept}
             ] =
               Wardrik.Host.children(host)

      assert kept == routed

      assert Wardrik.Host.settings(host, WardrikNotify)[:rooms] ==
               %WardrikChannel.Notices{settings: kept}

      assert WardrikChannel.attach(host(), channels: []) == host()
      assert_raise ArgumentError, fn -> WardrikChannel.attach(host(), mounts: []) end
    end
  end

  describe "config/2" do
    @types %{"test" => WardrikChannel.Test.Adapter}

    test "reads each channel, its adapter's settings by the adapter's own config/1" do
      assert {:ok, read} =
               WardrikChannel.config(
                 %{
                   "chat" => %{
                     "type" => "test",
                     "token" => "xoxb-1",
                     "test" => "me",
                     "approvers" => ["@maria"],
                     "admins" => ["@jon"]
                   },
                   "open" => %{
                     "type" => "test",
                     "test" => "you",
                     "approvers" => "anyone",
                     "create" => false
                   }
                 },
                 @types
               )

      assert Enum.sort(read[:channels]) == [
               chat: {WardrikChannel.Test.Adapter, test: "me"},
               open: {WardrikChannel.Test.Adapter, test: "you"}
             ]

      assert read[:tokens] == [chat: "xoxb-1"]
      assert Enum.sort(read[:creates]) == [chat: true, open: false]
      assert read[:approvers][:chat] == %WardrikChannel.Approvers.Named{names: ["@maria"]}
      assert read[:approvers][:open] == %WardrikChannel.Approvers.Anyone{}
      assert read[:admins][:chat] == ["@jon"]

      assert {:ok, none} = WardrikChannel.config(nil, @types)
      assert none[:channels] == []
    end

    test "says where a channel does not read" do
      for {section, path, message} <- [
            {"x", [], "is a set of keys"},
            {%{"chat" => "x"}, ["chat"], "is a set of keys"},
            {%{"chat" => %{"type" => "pigeon"}}, ["chat", "type"],
             "is the kind of channel: test"},
            {%{"chat" => %{"test" => "me"}}, ["chat", "type"], "is the kind of channel: test"},
            {%{"chat" => %{"type" => "test"}}, ["chat", "test"], "is required"},
            {%{"chat" => %{"type" => "test", "test" => "me", "create" => 1}}, ["chat", "create"],
             "is true or false"},
            {%{"chat" => %{"type" => "test", "test" => "me", "token" => ""}}, ["chat", "token"],
             "is the token the channel acts with, such as a bot's"},
            {%{"chat" => %{"type" => "test", "approvers" => "maria"}}, ["chat", "approvers"],
             "is anyone, or a list of who may answer, as the channel names them"},
            {%{"chat" => %{"type" => "test", "test" => "me", "admins" => "jon"}},
             ["chat", "admins"], "is a list of who may answer, as the channel names them"}
          ] do
        assert WardrikChannel.config(section, @types) == {:error, path, message}
      end

      assert WardrikChannel.config(%{"chat" => %{"type" => "test"}}, %{}) ==
               {:error, ["chat", "type"], "is the kind of channel, and this host has none"}
    end

    test "refuses a name its people could not be known by, or that Wardrik's own are" do
      for name <- ["Chat", "my_chat", "1chat", "ch at", "shell", "ssh", "terminal", "oauth"] do
        assert {:error, [^name], message} =
                 WardrikChannel.config(%{name => %{"type" => "test", "test" => "me"}}, @types)

        assert message =~ "is not a channel's name"
      end

      assert {:ok, _read} =
               WardrikChannel.config(%{"chat-2" => %{"type" => "test", "test" => "me"}}, @types)
    end
  end

  test "posts a notice in a room through the channel's adapter" do
    notice = notice()
    installation = installation()

    opts = [
      channel: {WardrikChannel.Test.Adapter, test: self()},
      installation: installation,
      room: "#ops",
      approvers: ["@maria"],
      req_options: [retry: false]
    ]

    assert :ok = WardrikChannel.Notices.deliver(notice, opts)

    assert_received {:delivered,
                     %Outbound{
                       installation: ^installation,
                       room: "#ops",
                       body: {:notice, ^notice},
                       approvers: ["@maria"]
                     }, channel}

    assert channel[:test] == self()
    assert channel[:req_options] == [retry: false]

    assert {:error, :no_room} =
             WardrikChannel.Notices.deliver(notice, Keyword.put(opts, :room, "#nowhere"))
  end

  describe "the rooms agents' routes name" do
    setup do
      {:ok, held} = Agent.start_link(fn -> %{} end)
      installations = %WardrikChannel.Test.Installations{agent: held}

      for org <- ["acme", "globex"],
          do:
            :ok =
              Installations.put(installations, %Installation{
                channel: "chat",
                workspace: "T-" <> org,
                owner: Resource.parse!(org),
                token: "token"
              })

      %{host: rooms_host(installations: installations)}
    end

    defp rooms_host(settings),
      do:
        WardrikChannel.attach(
          host(),
          [channels: [chat: {WardrikChannel.Test.Adapter, test: self()}]] ++ settings
        )

    # Posts a notice of `agent`'s in `room` through the rooms `host` holds.
    defp post(host, agent, room) do
      [channel, room] = String.split(room, ":")
      notice = %{notice() | agent: Wardrik.AgentID.parse!(agent)}

      Wardrik.Host.settings(host, WardrikNotify)[:rooms]
      |> WardrikNotify.Rooms.post(
        %WardrikDefinition.Room{channel: channel, room: room},
        notice,
        host: host,
        req_options: [retry: false]
      )
    end

    test "posts in a workspace of the agent's own owner, never another's", %{host: host} do
      for {agent, workspace} <- [
            {"acme/triage", "T-acme"},
            {"globex/triage", "T-globex"},
            {"acme/@jon/triage", "T-acme"}
          ] do
        assert :ok = post(host, agent, "chat:#updates")

        assert_received {:delivered,
                         %Outbound{
                           installation: %Installation{workspace: ^workspace},
                           room: "#updates",
                           body: {:notice, %Notice{agent: posted}},
                           approvers: []
                         }, channel}

        assert to_string(posted) == agent
        assert channel[:req_options] == [retry: false]
      end
    end

    test "posts nothing where its owner has the channel in no workspace, or there is none",
         %{host: host} do
      assert {:skip, "but chat is installed in no workspace of its owner's"} =
               post(host, "initech/triage", "chat:#updates")

      assert {:skip, "which names no channel of this host's"} =
               post(host, "acme/triage", "other:#updates")

      refute_received {:delivered, _outbound, _channel}
    end

    test "posts only the agents of the orgs the channel offers, every org's installation or not" do
      host =
        rooms_host(
          installations: Installations.Config.new([{:chat, "token", Resource.parse!("*")}]),
          orgs: [chat: ["acme"]]
        )

      assert :ok = post(host, "acme/triage", "chat:#updates")
      assert_received {:delivered, %Outbound{installation: %Installation{workspace: "chat"}}, _}

      assert {:skip, "but chat does not offer globex's agents"} =
               post(host, "globex/triage", "chat:#updates")

      refute_received {:delivered, _outbound, _channel}
    end
  end

  test "starts each channel's own, under its name" do
    test = self()
    {:ok, settings} = WardrikChannel.Test.Adapter.config(%{"test" => test})
    assert {:error, ["test"], _why} = WardrikChannel.Test.Adapter.config(%{})

    pid =
      start_supervised!(
        {WardrikChannel.Supervisor,
         host: host(),
         settings: [
           channels: [one: {WardrikChannel.Test.Adapter, settings}],
           installations: Installations.Config.new([])
         ]}
      )

    assert [{_tasks, _task_pid, :supervisor, _}, {{:channel, "one"}, channel, :worker, _}] =
             pid |> Supervisor.which_children() |> Enum.sort()

    assert Agent.get(channel, & &1)[:name] == "one"
    assert %WardrikChannel.Context{channel: "one"} = Agent.get(channel, & &1)[:context]
  end

  test "knows someone by the channel, the workspace and the id it knows them by" do
    named = {WardrikChannel.Test.Adapter, test: self()}
    member = WardrikChannel.Member.new(installation(), "U1")
    maria = WardrikChannel.principal(member, name: "maria")

    assert Wardrik.Principal.id(maria) == "named:T1/U1"
    assert WardrikChannel.person(maria) == {"named", "T1", "U1"}

    assert Wardrik.Principal.name(maria) == "maria"
    assert WardrikChannel.include?(named, ["U2", "U1"], member)
    refute WardrikChannel.include?(named, ["U2"], member)
    refute WardrikChannel.include?(named, [], member)
  end

  test "makes each channel, its context from what its settings say of it" do
    host = host()
    installations = Installations.Config.new([])
    approvers = %WardrikChannel.Approvers.Anyone{}

    assert %{
             "one" => %Channel{
               name: "one",
               adapter: WardrikChannel.Test.Adapter,
               options: [test: :me],
               context: context
             },
             "two" => %Channel{context: two}
           } =
             WardrikChannel.channels(
               [
                 channels: [
                   one: {WardrikChannel.Test.Adapter, test: :me},
                   two: {WardrikChannel.Test.Adapter, test: :you}
                 ],
                 installations: installations,
                 org: "acme",
                 orgs: [one: ["acme", "globex"]],
                 creates: [one: false],
                 approvers: [one: approvers]
               ],
               host: host,
               replies: :elsewhere
             )

    assert %WardrikChannel.Context{
             channel: "one",
             host: ^host,
             installations: ^installations,
             org: "acme",
             orgs: ["acme", "globex"],
             creates: false,
             approvers: ^approvers,
             replies: :elsewhere
           } = context

    assert %WardrikChannel.Context{orgs: :all, creates: true, approvers: %{names: []}} = two
  end

  test "hands a request the medium sent to the channel's adapter, as it was sent" do
    %{"one" => channel} =
      WardrikChannel.channels(
        [
          channels: [one: {WardrikChannel.Test.Adapter, test: self()}],
          installations: Installations.Config.new([])
        ],
        host: host()
      )

    assert %Response{status: 200, body: body} =
             WardrikChannel.request(channel, %{
               method: "POST",
               path: ["events"],
               headers: [{"x-signature", "v0=abc"}],
               body: ~s({"a":1})
             })

    assert JSON.decode!(body) == %{"path" => ["events"], "body" => ~s({"a":1})}
    assert_received {:request, request, opts}
    assert WardrikChannel.Request.header(request, "x-signature") == "v0=abc"
    assert WardrikChannel.Request.header(request, "x-other") == nil
    assert request.query == %{}
    assert opts[:name] == "one"
    assert %WardrikChannel.Context{channel: "one"} = opts[:context]
  end

  test "installs a channel for an owner, where its host keeps installations" do
    installations = %WardrikChannel.Test.Installations{
      agent: start_supervised!({Agent, fn -> %{} end})
    }

    %{"one" => channel} =
      WardrikChannel.channels(
        [
          channels: [one: {WardrikChannel.Test.Adapter, test: self()}],
          installations: installations
        ],
        host: host()
      )

    acme = Resource.parse!("acme")

    assert {:ok, "https://chat.example/install?owner=acme&return_to=/settings"} =
             WardrikChannel.install_url(channel, acme, return_to: "/settings")

    assert %Response{status: 302} =
             WardrikChannel.install(channel, acme, %{
               method: "GET",
               path: ["install"],
               query: %{"workspace" => "T7"},
               headers: [],
               body: ""
             })

    assert {:ok, %Installation{owner: ^acme, token: "token-T7"}} =
             Installations.fetch(installations, "one", "T7")
  end

  test "installs nothing more than its config names, from its config" do
    config = Installations.Config.new([{:slack, "xoxb-1", Resource.parse!("*")}])

    assert {:ok, %Installation{channel: "slack", workspace: "slack", token: "xoxb-1"}} =
             Installations.fetch(config, "slack", "T0123")

    assert :error = Installations.fetch(config, "other", "T0123")

    assert [%Installation{channel: "slack"}] =
             Installations.owned(config, "slack", Resource.parse!("*"))

    assert [] = Installations.owned(config, "slack", Resource.parse!("acme"))
    assert {:error, _why} = Installations.put(config, %{installation() | channel: "slack"})
    assert :ok = Installations.delete(config, "slack", "slack")
    assert {:ok, _still} = Installations.fetch(config, "slack", "slack")
    refute inspect(installation()) =~ "token"
  end

  test "runs what each channel runs, under its name, beside the channels' tasks" do
    {:ok, {_flags, [tasks | channels]}} =
      WardrikChannel.Supervisor.init(
        host: host(),
        settings: [
          channels: [
            one: {WardrikChannel.Test.Adapter, test: self()},
            two: {WardrikChannel.Test.Adapter, test: self()}
          ],
          installations: Installations.Config.new([])
        ]
      )

    assert tasks.id == WardrikChannel.tasks()

    assert [
             %{id: {:channel, "one"}, start: {Agent, :start_link, [one]}},
             %{id: {:channel, "two"}}
           ] =
             Enum.sort_by(channels, & &1.id)

    assert one.()[:name] == "one"
  end
end
