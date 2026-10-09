defmodule WardrikSlack.AnswersTest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.Test.AgentRunners
  alias WardrikSlack.Answers

  @req_options [plug: {Req.Test, WardrikSlack.Stub}]

  setup do
    test = self()

    Req.Test.stub(WardrikSlack.Stub, fn conn ->
      send(test, {:slack, conn.host, conn.request_path, JSON.decode!(Req.Test.raw_body(conn))})

      case conn.request_path do
        "/api/users.info" ->
          Req.Test.json(conn, %{ok: true, user: %{profile: %{email: "Jon@Example.com"}}})

        _other ->
          Req.Test.json(conn, %{ok: true})
      end
    end)

    :ok
  end

  # The channel's options a press is answered with.
  defp answering, do: [token: "xoxb-test", req_options: @req_options]

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
      assert :ok = Answers.answer(press(key, "wardrik_link"), answering())

      assert_receive {:slack, "hooks.slack.com", _path, reply}
      assert reply["response_type"] == "ephemeral"
      assert reply["replace_original"] == false
      assert reply["text"] == "Enter `WDJB-MJHT` at https://github.com/login/device"
      assert [{%{id: "call_1"}, _prompt}] = Agent.parked(key)
    end

    test "is refused to someone who is not an approver", %{key: key} do
      assert :ok = Answers.answer(press(key, "wardrik_link", "U1", nil, ["U2"]), answering())

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
      assert :ok = Answers.answer(press(key, "wardrik_link"), answering())

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

    defp press(key, action, user \\ "U1", reason \\ nil, approvers \\ []) do
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
            "value" => JSON.encode!(%{a: to_string(key), c: "call_1", n: "deploy", p: approvers})
          }
        ]
      }
    end

    test "approves the call, and says who did in place of the buttons", %{key: key} do
      assert :ok = Answers.answer(press(key, "wardrik_approve"), answering())

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
      assert :ok = Answers.answer(press(key, "wardrik_deny"), answering())

      assert_receive {:resumed, %{"call_1" => {:deny, "Denied in Slack by jon."}}}
    end

    test "denies the call with what was written in its box, and says it in place of the box",
         %{key: key} do
      assert :ok =
               Answers.answer(
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
      assert :ok = Answers.answer(press(key, "wardrik_approve", "U1", "Fine by me."), answering())
      assert_receive {:resumed, %{"call_1" => :approve}}

      assert_receive {:slack, _host, _path, reply}
      refute JSON.encode!(reply) =~ "Fine by me."
    end

    test "refuses someone who is not an approver", %{key: key} do
      assert :ok = Answers.answer(press(key, "wardrik_approve", "U1", nil, ["U2"]), answering())

      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "approvers"
      assert [{%{id: "call_1"}, _prompt}] = Agent.parked(key)
    end

    test "takes an approver by @handle, or by email address", %{key: key} do
      assert :ok =
               Answers.answer(
                 press(key, "wardrik_approve", "U1", nil, ["U2", "@jon"]),
                 answering()
               )

      assert_receive {:resumed, _decisions}
      refute_received {:slack, _host, "/api/users.info", _body}
    end

    test "looks up the presser's email address where an approver is named by one", %{key: key} do
      assert :ok =
               Answers.answer(
                 press(key, "wardrik_approve", "U1", nil, ["@maria", "jon@example.com"]),
                 answering()
               )

      assert_receive {:slack, _host, "/api/users.info", %{"user" => "U1"}}
      assert_receive {:resumed, _decisions}

      assert :ok =
               Answers.answer(
                 press(key, "wardrik_approve", "U1", nil, ["maria@example.com"]),
                 answering()
               )

      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "approvers"
    end

    test "says a second press finds the question answered", %{key: key} do
      assert :ok = Answers.answer(press(key, "wardrik_approve"), answering())
      assert_receive {:resumed, _decisions}
      assert_receive {:slack, _host, _path, %{"replace_original" => true}}

      assert :ok = Answers.answer(press(key, "wardrik_approve"), answering())
      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "already answered"
    end

    test "says so when the agent cannot record the answer", %{key: key} do
      :ok = Wardrik.Test.EventLog.usurp(key)

      assert :ok = Answers.answer(press(key, "wardrik_approve"), answering())
      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "could not record"
    end

    test "says so when the agent is not running", %{key: key} do
      :ok = Fleet.forget(key)

      assert :ok = Answers.answer(press(key, "wardrik_approve"), answering())
      assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
      assert text =~ "is not running"
    end

    test "ignores a press that is not one of its buttons" do
      assert Answers.answer(%{"actions" => [%{"action_id" => "other", "value" => "{}"}]}) ==
               :ignored
    end
  end
end
