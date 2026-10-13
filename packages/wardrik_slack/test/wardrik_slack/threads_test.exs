defmodule WardrikSlack.ThreadsTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Fleet
  alias Wardrik.Test.AgentRunners
  alias WardrikChannel.Context
  alias WardrikChannel.Offer
  alias WardrikChannel.Replies
  alias WardrikChannel.Rooms
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

  @doc false
  def offering(agent, _channel), do: [%Offer{agent: agent}]

  @doc false
  def starting(runner, _channel, agent), do: Fleet.spawn(agent, runner: runner)

  # A Slack channel's agent, whose threads run on `runner`, bound to C1.
  defp bound(runner) do
    agent = Wardrik.Test.Fleet.id("books")

    context = %Context{
      host: Wardrik.Host.new(),
      channel: "slack-#{System.unique_integer([:positive])}",
      offered: {__MODULE__, :offering, [agent]},
      start: {__MODULE__, :starting, [runner]}
    }

    channel = [token: "xoxb-test", req_options: @req_options]
    :ok = WardrikChannel.put_channel(WardrikSlack, channel, context)
    {:bound, _room, _offer} = Rooms.joined(context, "C1", "books", nil)

    on_exit(fn ->
      Replies.forget(context.channel, "C1")
      Fleet.forget_under(AgentID.Prefix.of(agent))
    end)

    people = :ets.new(:people, [:public])
    [context: context, name: :slack, bot: "UBOT", team: "T1", people: people] ++ channel
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

    assert {:asked, agent} = Threads.message(message(%{}), opts)
    assert agent.external_id == "C1-1.1"

    assert %{"user" => "U1"} = called("/api/users.info")

    assert called("/api/reactions.add") ==
             %{"channel" => "C1", "timestamp" => "1.1", "name" => "eyes"}

    assert_receive {:turn, turn}
    assert {:user, "From maria (channel slack/U1):\nHow much Barolo is left?"} in turn

    assert %{
             "channel" => "C1",
             "thread_ts" => "1.1",
             "text" => "Two **cases**.",
             "blocks" => [%{"type" => "markdown", "text" => "Two **cases**."}]
           } = called("/api/chat.postMessage")

    assert %{"name" => "eyes", "timestamp" => "1.1"} = called("/api/reactions.remove")
    assert %{"name" => "white_check_mark", "timestamp" => "1.1"} = called("/api/reactions.add")

    reply = message(%{"ts" => "1.2", "thread_ts" => "1.1", "text" => "And Nebbiolo?"})
    assert Threads.message(reply, opts) == {:asked, agent}
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
      assert Threads.message(passed, opts) == :ignored
    end

    refute_received {:slack, _path, _body}
  end

  test "says in the thread why its agent could not be asked" do
    opts = bound({AgentRunners, :echo, [self(), "Here."]})
    opts = Keyword.update!(opts, :context, &%{&1 | start: {Context, :unstarted, []}})

    assert {:error, message} = Threads.message(message(%{}), opts)

    assert %{"thread_ts" => "1.1", "text" => ":warning: " <> ^message} =
             called("/api/chat.postMessage")

    refute_received {:slack, "/api/reactions.add", _body}
  end

  test "names someone Slack does not know by their id alone" do
    Req.Test.stub(WardrikSlack.Stub, &Req.Test.json(&1, %{ok: false, error: "user_not_found"}))

    opts = bound({AgentRunners, :echo, [self(), "Here."]})
    assert {:asked, _agent} = Threads.message(message(%{}), opts)
    assert_receive {:turn, turn}
    assert {:user, "From channel slack/U1:\nHow much Barolo is left?"} in turn
  end
end
