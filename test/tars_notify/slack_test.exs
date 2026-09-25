defmodule TarsNotify.SlackTest do
  use ExUnit.Case, async: false

  alias Tars.Agent
  alias Tars.Event
  alias Tars.Fleet
  alias Tars.Test.AgentRunners
  alias TarsNotify.Notice
  alias TarsNotify.Slack

  @target [channel: "#ops", token: "xoxb-test", app_token: "xapp-test"]

  setup do
    previous = Application.get_env(:tars, TarsNotify)
    Application.put_env(:tars, TarsNotify, Keyword.put(previous, :targets, ops: {Slack, @target}))
    on_exit(fn -> Application.put_env(:tars, TarsNotify, previous) end)

    test = self()

    Req.Test.stub(TarsNotify.Stub, fn conn ->
      send(test, {:slack, conn.host, conn.request_path, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{ok: true})
    end)

    :ok
  end

  defp parked_notice do
    %Notice{
      agent: "acme/_/triage",
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
      assert message["text"] == "acme/_/triage is waiting on you: deploy"

      assert %{"elements" => [approve, deny]} =
               Enum.find(message["blocks"], &(&1["block_id"] == "tars:call_1"))

      assert approve["action_id"] == "tars_approve"
      assert deny["action_id"] == "tars_deny"

      assert JSON.decode!(approve["value"]) == %{
               "a" => "acme/_/triage",
               "c" => "call_1",
               "n" => "deploy",
               "t" => "ops"
             }
    end

    test "says how to answer from a shell when there is no app token" do
      assert :ok =
               Slack.deliver(parked_notice(), target: :ops, channel: "#ops", token: "xoxb-test")

      assert_receive {:slack, _host, "/api/chat.postMessage", message}
      refute Enum.any?(message["blocks"], &(&1["type"] == "actions"))
      assert JSON.encode!(message["blocks"]) =~ "tars approve acme/_/triage call_1"
    end

    test "posts what a turn failed of, and what one answered" do
      failed = %{parked_notice() | kind: :failed, calls: [], reason: :timeout}
      assert :ok = Slack.deliver(failed, [target: :ops] ++ @target)

      assert_receive {:slack, _host, _path,
                      %{"text" => "acme/_/triage failed", "blocks" => [block]}}

      assert block["text"]["text"] =~ ":timeout"

      answered = %{parked_notice() | kind: :finished, calls: [], text: "Two incidents need you."}
      assert :ok = Slack.deliver(answered, [target: :ops] ++ @target)

      assert_receive {:slack, _host, _path,
                      %{"text" => "acme/_/triage answered", "blocks" => [_title, body]}}

      assert body["text"]["text"] == "Two incidents need you."
    end

    test "reports what Slack refused" do
      Req.Test.stub(TarsNotify.Stub, &Req.Test.json(&1, %{ok: false, error: "channel_not_found"}))

      assert {:error, "channel_not_found"} =
               Slack.deliver(parked_notice(), [target: :ops] ++ @target)
    end
  end

  describe "answer/1" do
    setup do
      key = Fleet.key("slack-#{System.unique_integer([:positive])}")

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

    defp press(key, action, user \\ "U1") do
      %{
        "type" => "block_actions",
        "user" => %{"id" => user, "username" => "jon"},
        "response_url" => "https://hooks.slack.com/actions/r",
        "message" => %{
          "blocks" => [
            %{"type" => "section"},
            %{"type" => "actions", "block_id" => "tars:call_1"}
          ]
        },
        "actions" => [
          %{
            "action_id" => action,
            "value" => JSON.encode!(%{a: key, c: "call_1", n: "deploy", t: "ops"})
          }
        ]
      }
    end

    test "approves the call, and says who did in place of the buttons", %{key: key} do
      assert :ok = Slack.answer(press(key, "tars_approve"))

      assert_receive {:resumed, %{"call_1" => :approve}}

      assert_receive %Event{
        payload:
          {:call_decided, "call_1", :approve,
           %Tars.Principal{type: :slack, id: "U1", name: "jon"}}
      }

      assert_receive {:slack, "hooks.slack.com", "/actions/r", reply}
      assert reply["replace_original"] == true
      assert [%{"type" => "section"}, %{"type" => "context"} = line] = reply["blocks"]
      assert JSON.encode!(line) =~ "Approved `deploy`"
      assert JSON.encode!(line) =~ "<@U1>"
    end

    test "denies the call in the name of whoever pressed", %{key: key} do
      assert :ok = Slack.answer(press(key, "tars_deny"))

      assert_receive {:resumed, %{"call_1" => {:deny, "Denied in Slack by jon."}}}
    end

    test "refuses someone who is not an approver", %{key: key} do
      Application.put_env(
        :tars,
        TarsNotify,
        Keyword.put(Application.get_env(:tars, TarsNotify), :targets,
          ops: {Slack, [approvers: ["U2"]] ++ @target}
        )
      )

      assert :ok = Slack.answer(press(key, "tars_approve", "U1"))

      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "approvers"
      assert [{%{id: "call_1"}, _prompt}] = Agent.parked(key)
    end

    test "says a second press finds the question answered", %{key: key} do
      assert :ok = Slack.answer(press(key, "tars_approve"))
      assert_receive {:resumed, _decisions}
      assert_receive {:slack, _host, _path, %{"replace_original" => true}}

      assert :ok = Slack.answer(press(key, "tars_approve"))
      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "already answered"
    end

    test "says so when the agent cannot record the answer", %{key: key} do
      :ok = Tars.Test.EventLog.usurp(key)

      assert :ok = Slack.answer(press(key, "tars_approve"))
      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "could not record"
    end

    test "says so when the agent is not running", %{key: key} do
      :ok = Fleet.forget(key)

      assert :ok = Slack.answer(press(key, "tars_approve"))
      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "is not running"
    end

    test "ignores a press that is not one of its buttons" do
      assert Slack.answer(%{"actions" => [%{"action_id" => "other", "value" => "{}"}]}) ==
               :ignored
    end
  end
end
