defmodule WardrikSlack.ThreadsTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Fleet
  alias Wardrik.Resource
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Script
  alias WardrikChannel.Installations
  alias WardrikChannel.Replies
  alias WardrikChannel.Rooms
  alias WardrikChannel.Workspace
  alias WardrikSlack.Threads

  @req_options [plug: {Req.Test, WardrikSlack.Stub}]

  setup :set_req_test_to_shared

  setup do
    test = self()

    Req.Test.stub(WardrikSlack.Stub, fn conn ->
      body = JSON.decode!(Req.Test.raw_body(conn))
      send(test, {:slack, conn.request_path, body})

      case conn.request_path do
        "/api/users.info" ->
          Req.Test.json(conn, %{
            ok: true,
            user: %{name: "maria.c", profile: %{display_name: "maria"}}
          })

        _other ->
          Req.Test.json(conn, %{ok: true, ts: "9.9"})
      end
    end)

    :ok
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  # Everyone in the workspace may read and message every agent, as the
  # daemon's issuer lets the people of a channel read and message its orgs'
  # agents.
  defmodule Everyone do
    @moduledoc false
    defstruct []
  end

  defimpl Wardrik.Issuer, for: Everyone do
    def issue(_everyone, principal, _opts) do
      %Wardrik.Token{
        principal: principal,
        scope: [Wardrik.Role.bind([:reader, :messenger], [Resource.parse!("*")])]
      }
    end
  end

  # A Slack channel's agent, its host's, bound to C1, and posted in by a
  # WardrikChannel.Replies of its own started with it. The agent of the
  # thread 1.1 runs on `runner`, as one started before the channel starts
  # it would.
  defp bound(runner) do
    agent = Wardrik.Test.Fleet.id("books")
    name = "slack-#{System.unique_integer([:positive])}"
    replies = :"replies-#{name}"
    host = WardrikSlack.Test.host([], issuer: %Everyone{})
    WardrikSlack.Test.define(host, agent, %{"channels" => [name]})

    settings = [
      channels: [{name, {WardrikSlack, req_options: @req_options}}],
      installations: Installations.Config.new([{name, "xoxb-test", Wardrik.Resource.parse!("*")}])
    ]

    start_supervised!({Replies, name: replies, host: host, settings: settings})
    :ok = DurableServer.Supervisor.wait_until_ready(replies, timeout: 10_000)
    %{^name => channel} = WardrikChannel.channels(settings, host: host, replies: replies)
    {:ok, workspace} = Workspace.new(channel.context, "T1")

    {:bound, room, _offer} = Rooms.joined(WardrikChannel.Room.new(workspace, "C1"), name: "books")

    {:ok, _pid} =
      Fleet.spawn(WardrikChannel.conversation(room, "1.1"), config: Script.new(runner))

    itself = AgentID.resource(agent)
    on_exit(fn -> Enum.each([itself, Resource.parse!("#{itself}/*")], &Fleet.forget_under/1) end)
    on_exit(fn -> Wardrik.Definitions.delete(Wardrik.Host.definitions(host), agent) end)

    [
      workspace: workspace,
      token: "xoxb-test",
      bot: "UBOT",
      team: "T1",
      req_options: @req_options
    ]
  end

  # How the agent reads the sender, of the test's channel.
  defp from(opts) do
    %{channel: channel, workspace: workspace} = opts[:workspace].installation
    "#{channel}:#{workspace}/U1"
  end

  defp message(fields) do
    Map.merge(
      %{
        "type" => "message",
        "channel" => "C1",
        "channel_type" => "channel",
        "user" => "U1",
        "team" => "T1",
        "ts" => "1.1",
        "text" => "<@UBOT> How much Barolo is left?"
      },
      fields
    )
  end

  defp called(path) do
    assert_receive {:slack, ^path, body}
    body
  end

  test "asks the Slack channel's agent, and answers in the thread, marking what it answered" do
    opts = bound({AgentRunners, :echo, [self(), "Two **cases**."]})

    assert {:asked, agent} = Threads.event(message(%{}), opts)
    assert %Wardrik.Thread{id: "C1-1.1"} = agent

    assert %{"user" => "U1"} = called("/api/users.info")

    assert called("/api/reactions.add") ==
             %{"channel" => "C1", "timestamp" => "1.1", "name" => "eyes"}

    assert_receive {:turn, turn}
    assert {:user, "From maria (#{from(opts)}):\nHow much Barolo is left?"} in turn

    assert %{
             "channel" => "C1",
             "thread_ts" => "1.1",
             "text" => "Two **cases**.",
             "blocks" => [%{"type" => "markdown", "text" => "Two **cases**."}]
           } = called("/api/chat.postMessage")

    assert %{"name" => "eyes", "timestamp" => "1.1"} = called("/api/reactions.remove")
    assert %{"name" => "white_check_mark", "timestamp" => "1.1"} = called("/api/reactions.add")

    reply = message(%{"ts" => "1.2", "thread_ts" => "1.1", "text" => "And Nebbiolo?"})
    assert Threads.event(reply, opts) == {:asked, agent}
    refute_received {:slack, "/api/users.info", _body}
    assert %{"timestamp" => "1.2", "name" => "eyes"} = called("/api/reactions.add")
    assert %{"thread_ts" => "1.1"} = called("/api/chat.postMessage")
    assert %{"name" => "white_check_mark", "timestamp" => "1.2"} = called("/api/reactions.add")
  end

  test "passes over changes, bots, itself, direct messages and other workspaces" do
    opts = bound({AgentRunners, :echo, [self(), "Here."]})

    for passed <- [
          message(%{"subtype" => "message_changed"}),
          message(%{"bot_id" => "B1"}),
          message(%{"user" => "UBOT"}),
          message(%{"channel_type" => "im"}),
          message(%{"user_team" => "T2"}),
          %{"type" => "message", "subtype" => "message_deleted", "channel" => "C1"},
          %{"type" => "reaction_added"}
        ] do
      assert Threads.event(passed, opts) == :ignored
    end

    refute_received {:slack, _path, _body}
  end

  test "says in the thread why its agent could not be asked" do
    opts = bound({AgentRunners, :echo, [self(), "Here."]})

    undefined = Wardrik.Host.new(store: Wardrik.Test.store(), issuer: %Everyone{})

    opts =
      Keyword.update!(opts, :workspace, fn workspace ->
        %{workspace | context: %{workspace.context | host: undefined}}
      end)

    assert {:error, message} = Threads.event(message(%{"ts" => "2.1"}), opts)
    assert message =~ "is not defined"

    assert %{"thread_ts" => "2.1", "text" => ":warning: " <> ^message} =
             called("/api/chat.postMessage")

    refute_received {:slack, "/api/reactions.add", _body}
  end

  test "names someone Slack does not know by their id alone" do
    test = self()

    Req.Test.stub(WardrikSlack.Stub, fn conn ->
      send(test, {:slack, conn.request_path, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{ok: false, error: "user_not_found"})
    end)

    opts = bound({AgentRunners, :echo, [self(), "Here."]})
    assert {:asked, _agent} = Threads.event(message(%{}), opts)
    assert_receive {:turn, turn}
    assert {:user, "From #{from(opts)}:\nHow much Barolo is left?"} in turn
    assert %{"text" => "Here."} = called("/api/chat.postMessage")
  end
end
