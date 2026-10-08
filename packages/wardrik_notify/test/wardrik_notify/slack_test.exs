defmodule WardrikNotify.SlackTest do
  use ExUnit.Case, async: false

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.Test.AgentRunners
  alias WardrikNotify.Notice
  alias WardrikNotify.Slack

  @req_options [plug: {Req.Test, WardrikNotify.Stub}]
  @target [channel: "#ops", token: "xoxb-test", app_token: "xapp-test", req_options: @req_options]

  setup do
    test = self()

    Req.Test.stub(WardrikNotify.Stub, fn conn ->
      send(test, {:slack, conn.host, conn.request_path, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{ok: true})
    end)

    :ok
  end

  defp parked_notice do
    %Notice{
      agent: ~A"acme/triage",
      kind: :parked,
      at: ~U[2026-09-24 09:30:00Z],
      calls: [
        %{id: "call_1", name: "deploy", arguments: %{"env" => "prod"}, prompt: "This ships."}
      ]
    }
  end

  describe "deliver/2" do
    test "posts a parked turn with buttons on each call" do
      assert :ok = Slack.deliver(parked_notice(), [target: :ops] ++ @target)

      assert_receive {:slack, "slack.com", "/api/chat.postMessage", message}
      assert message["channel"] == "#ops"
      assert message["text"] == "acme/triage is waiting on you: deploy"

      assert %{"elements" => [approve, deny]} =
               Enum.find(message["blocks"], &(&1["block_id"] == "wardrik:call_1"))

      assert approve["action_id"] == "wardrik_approve"
      assert deny["action_id"] == "wardrik_deny"

      assert JSON.decode!(approve["value"]) == %{
               "a" => "acme/triage",
               "c" => "call_1",
               "n" => "deploy",
               "t" => "ops"
             }
    end

    test "gives each call a box for why it is denied, above its buttons" do
      assert :ok = Slack.deliver(parked_notice(), [target: :ops] ++ @target)
      assert_receive {:slack, "slack.com", "/api/chat.postMessage", message}

      ids = Enum.map(message["blocks"], & &1["block_id"])

      assert Enum.find_index(ids, &(&1 == "wardrik-reason:call_1")) ==
               Enum.find_index(ids, &(&1 == "wardrik:call_1")) - 1

      box = Enum.find(message["blocks"], &(&1["block_id"] == "wardrik-reason:call_1"))

      assert %{"type" => "input", "optional" => true, "element" => %{"action_id" => "reason"}} =
               box
    end

    test "says what the turn had read, which may be what asked for the call" do
      [call] = parked_notice().calls
      notice = %{parked_notice() | calls: [Map.put(call, :labels, ["outside", "books"])]}

      assert :ok = Slack.deliver(notice, [target: :ops] ++ @target)
      assert_receive {:slack, _host, "/api/chat.postMessage", message}

      assert JSON.encode!(message["blocks"]) =~
               "It has read content from outside and content labelled books"
    end

    test "says how to answer from a shell when there is no app token" do
      assert :ok =
               Slack.deliver(parked_notice(),
                 target: :ops,
                 channel: "#ops",
                 token: "xoxb-test",
                 req_options: @req_options
               )

      assert_receive {:slack, _host, "/api/chat.postMessage", message}
      refute Enum.any?(message["blocks"], &(&1["type"] in ["actions", "input"]))
      assert JSON.encode!(message["blocks"]) =~ "wardrik approve acme/triage call_1"
    end

    test "posts what a turn failed of, and what one answered" do
      failed = %{parked_notice() | kind: :failed, calls: [], reason: :timeout}
      assert :ok = Slack.deliver(failed, [target: :ops] ++ @target)

      assert_receive {:slack, _host, _path,
                      %{"text" => "acme/triage failed", "blocks" => [block]}}

      assert block["text"]["text"] =~ ":timeout"

      answered = %{parked_notice() | kind: :finished, calls: [], text: "Two incidents need you."}
      assert :ok = Slack.deliver(answered, [target: :ops] ++ @target)

      assert_receive {:slack, _host, _path,
                      %{"text" => "acme/triage answered", "blocks" => [_title, body]}}

      assert body["text"]["text"] == "Two incidents need you."
    end

    test "reports what Slack refused" do
      Req.Test.stub(
        WardrikNotify.Stub,
        &Req.Test.json(&1, %{ok: false, error: "channel_not_found"})
      )

      assert {:error, "channel_not_found"} =
               Slack.deliver(parked_notice(), [target: :ops] ++ @target)
    end
  end

  defp answering(targets \\ [ops: {Slack, @target}]),
    do: [targets: targets, req_options: @req_options]

  describe "a call waiting on a person to connect an account" do
    defp connecting_notice do
      %Notice{
        agent: ~A"acme/triage",
        kind: :parked,
        at: ~U[2026-09-24 09:30:00Z],
        calls: [
          %{
            id: "call_1",
            name: "github__issues",
            arguments: %{},
            prompt: "To connect github, open its authorization link.",
            authorization: true
          }
        ]
      }
    end

    test "is posted with Show link and Deny, and no link" do
      assert :ok = Slack.deliver(connecting_notice(), [target: :ops] ++ @target)
      assert_receive {:slack, "slack.com", "/api/chat.postMessage", message}

      assert %{"elements" => [show, deny]} =
               Enum.find(message["blocks"], &(&1["block_id"] == "wardrik:call_1"))

      assert show["action_id"] == "wardrik_link"
      assert deny["action_id"] == "wardrik_deny"
      refute JSON.encode!(message) =~ "https://"
      refute Enum.any?(message["blocks"], &(&1["type"] == "input"))
    end

    test "says to find the link with wardrik parked where there is no app token" do
      assert :ok =
               Slack.deliver(connecting_notice(),
                 channel: "#ops",
                 token: "xoxb-test",
                 req_options: @req_options
               )

      assert_receive {:slack, _host, _path, message}
      assert JSON.encode!(message) =~ "Find the link with `wardrik parked`"
    end
  end

  describe "Show link" do
    setup do
      key = Wardrik.Test.Fleet.id("slack-link")
      link = %{url: "https://github.com/login/device", code: "WDJB-MJHT"}

      {:ok, _pid} =
        Fleet.spawn(key,
          runner: {AgentRunners, :connecting, [self(), "call_1", link]},
          resumer: {AgentRunners, :resuming, [self(), {:ok, []}]}
        )

      on_exit(fn -> Fleet.forget(key) end)
      :ok = Event.Bus.subscribe(key, level: :lifecycle)
      :ok = Agent.ask(key, "Open an issue.")
      assert_receive %Event{payload: {:turn_parked, _calls}}

      %{key: key}
    end

    test "tells the person pressing alone where to connect, and decides nothing", %{key: key} do
      assert :ok = Slack.answer(press(key, "wardrik_link"), answering())

      assert_receive {:slack, "hooks.slack.com", _path, reply}
      assert reply["response_type"] == "ephemeral"
      assert reply["replace_original"] == false
      assert reply["text"] == "Enter `WDJB-MJHT` at https://github.com/login/device"
      assert [{%{id: "call_1"}, _prompt}] = Agent.parked(key)
    end

    test "is refused to someone who is not an approver", %{key: key} do
      targets = [ops: {Slack, [approvers: ["U2"]] ++ @target}]

      assert :ok = Slack.answer(press(key, "wardrik_link", "U1"), answering(targets))

      assert_receive {:slack, _host, _path, %{"text" => text}}
      assert text =~ "approvers"
      refute text =~ "WDJB-MJHT"
    end

    test "says so once nothing waits on a connection", %{key: key} do
      :ok =
        Agent.decide(key, %{"call_1" => {:deny, "Not now."}},
          by: Wardrik.Principal.new(:shell, "t")
        )

      assert_receive {:resumed, %{"call_1" => {:deny, "Not now."}}}
      assert :ok = Slack.answer(press(key, "wardrik_link"), answering())

      assert_receive {:slack, _host, _path, %{"text" => text}}
      assert text == "That is no longer waiting on anyone to connect."
    end
  end

  describe "answer/1" do
    setup do
      key = Wardrik.Test.Fleet.id("slack")

      {:ok, _pid} =
        Fleet.spawn(key,
          runner: {AgentRunners, :parking, [self(), "call_1"]},
          resumer: {AgentRunners, :resuming, [self(), {:ok, []}]}
        )

      on_exit(fn -> Fleet.forget(key) end)
      :ok = Event.Bus.subscribe(key, level: :lifecycle)
      :ok = Agent.ask(key, "Ship it.")
      assert_receive %Event{payload: {:turn_parked, _calls}}

      %{key: key}
    end

    defp press(key, action, user \\ "U1", reason \\ nil) do
      %{
        "state" => %{
          "values" => %{"wardrik-reason:call_1" => %{"reason" => %{"value" => reason}}}
        },
        "type" => "block_actions",
        "user" => %{"id" => user, "username" => "jon"},
        "response_url" => "https://hooks.slack.com/actions/r",
        "message" => %{
          "blocks" => [
            %{"type" => "section"},
            %{"type" => "input", "block_id" => "wardrik-reason:call_1"},
            %{"type" => "actions", "block_id" => "wardrik:call_1"}
          ]
        },
        "actions" => [
          %{
            "action_id" => action,
            "value" => JSON.encode!(%{a: to_string(key), c: "call_1", n: "deploy", t: "ops"})
          }
        ]
      }
    end

    test "approves the call, and says who did in place of the buttons", %{key: key} do
      assert :ok = Slack.answer(press(key, "wardrik_approve"), answering())

      assert_receive {:resumed, %{"call_1" => :approve}}

      jon = Wardrik.Principal.new(:slack, "U1", name: "jon")
      assert_receive %Event{payload: {:call_decided, "call_1", :approve, ^jon}}

      assert_receive {:slack, "hooks.slack.com", "/actions/r", reply}
      assert reply["replace_original"] == true
      assert [%{"type" => "section"}, %{"type" => "context"} = line] = reply["blocks"]
      assert JSON.encode!(line) =~ "Approved `deploy`"
      assert JSON.encode!(line) =~ "<@U1>"
    end

    test "denies the call in the name of whoever pressed", %{key: key} do
      assert :ok = Slack.answer(press(key, "wardrik_deny"), answering())

      assert_receive {:resumed, %{"call_1" => {:deny, "Denied in Slack by jon."}}}
    end

    test "denies the call with what was written in its box, and says it in place of the box",
         %{key: key} do
      assert :ok =
               Slack.answer(
                 press(key, "wardrik_deny", "U1", "  Deploy to staging first.\n"),
                 answering()
               )

      assert_receive {:resumed,
                      %{"call_1" => {:deny, "Denied in Slack by jon: Deploy to staging first."}}}

      assert_receive {:slack, "hooks.slack.com", "/actions/r", reply}
      assert [%{"type" => "section"}, %{"type" => "context"} = line] = reply["blocks"]
      assert JSON.encode!(line) =~ "Denied `deploy`"
      assert JSON.encode!(line) =~ "Deploy to staging first."
    end

    test "approves without what was written in the box, and leaves a blank box unsaid",
         %{key: key} do
      assert :ok = Slack.answer(press(key, "wardrik_approve", "U1", "Fine by me."), answering())
      assert_receive {:resumed, %{"call_1" => :approve}}

      assert_receive {:slack, _host, _path, reply}
      refute JSON.encode!(reply) =~ "Fine by me."
    end

    test "refuses someone who is not an approver", %{key: key} do
      targets = [ops: {Slack, [approvers: ["U2"]] ++ @target}]

      assert :ok = Slack.answer(press(key, "wardrik_approve", "U1"), answering(targets))

      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "approvers"
      assert [{%{id: "call_1"}, _prompt}] = Agent.parked(key)
    end

    test "says a second press finds the question answered", %{key: key} do
      assert :ok = Slack.answer(press(key, "wardrik_approve"), answering())
      assert_receive {:resumed, _decisions}
      assert_receive {:slack, _host, _path, %{"replace_original" => true}}

      assert :ok = Slack.answer(press(key, "wardrik_approve"), answering())
      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "already answered"
    end

    test "says so when the agent cannot record the answer", %{key: key} do
      :ok = Wardrik.Test.EventLog.usurp(key)

      assert :ok = Slack.answer(press(key, "wardrik_approve"), answering())
      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "could not record"
    end

    test "says so when the agent is not running", %{key: key} do
      :ok = Fleet.forget(key)

      assert :ok = Slack.answer(press(key, "wardrik_approve"), answering())
      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "is not running"
    end

    test "ignores a press that is not one of its buttons" do
      assert Slack.answer(%{"actions" => [%{"action_id" => "other", "value" => "{}"}]}) ==
               :ignored
    end
  end
end
