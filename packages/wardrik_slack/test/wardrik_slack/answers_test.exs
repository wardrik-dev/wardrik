defmodule WardrikSlack.AnswersTest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.Test.AgentRunners
  alias WardrikSlack.Answers

  @req_options [plug: {Req.Test, WardrikSlack.Stub}]

  # U1 may decide every agent's calls; U2 may read and message them; nobody
  # else holds anything.
  defmodule Held do
    @moduledoc false
    defstruct []

    def issue(_host, principal, _opts) do
      roles =
        case Wardrik.Principal.id(principal) do
          "slack/T1/U1" -> [[:reader, :messenger, :approver]]
          "slack/T1/U2" -> [[:reader, :messenger]]
          _anyone -> []
        end

      %Wardrik.Token{
        principal: principal,
        scope: for(held <- roles, do: Wardrik.Role.bind(held, Wardrik.AgentID.Prefix.all()))
      }
    end
  end

  defimpl Wardrik.Issuer, for: Held do
    defdelegate issue(a0, a1, a2), to: Held
  end

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

  @doc false
  def deciding(_installation), do: "The org's approvers, in its settings, name who else may."

  # The channel's options a press is answered with.
  defp answering do
    context = %WardrikChannel.Context{
      channel: "slack",
      host: Wardrik.Host.new(store: Wardrik.Test.store(), issuer: %Held{}),
      installations: WardrikChannel.Installations.Config.new([])
    }

    workspace = %WardrikChannel.Workspace{
      context: context,
      installation: WardrikSlack.Test.installation()
    }

    [workspace: workspace, token: "xoxb-test", req_options: @req_options]
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
      :ok = Agent.ask(key, "Open an issue.", host: Wardrik.Test.host())
      assert_receive %Event{payload: %Event.TurnParked{}}

      %{key: key}
    end

    test "tells the person pressing alone where to connect, and decides nothing", %{key: key} do
      assert :ok = Answers.answer(press(key, "wardrik_link"), answering())

      assert_receive {:slack, "hooks.slack.com", _path, reply}
      assert reply["response_type"] == "ephemeral"
      assert reply["replace_original"] == false
      assert reply["text"] == "Enter `WDJB-MJHT` at https://github.com/login/device"
      assert [{%{id: "call_1"}, _prompt}] = Agent.parked(key, host: Wardrik.Test.host())
    end

    test "is refused to someone who may not decide, saying who else may as the host words it",
         %{key: key} do
      assert :ok = Answers.answer(press(key, "wardrik_link", "U2"), answering())

      assert_receive {:slack, _host, _path, %{"text" => text}}

      assert text ==
               "Only whoever asked, or the approvers here, can answer that. " <>
                 "Whoever runs Wardrik names who else may."

      refute text =~ "WDJB-MJHT"

      opts =
        Keyword.update!(answering(), :workspace, fn workspace ->
          %{workspace | context: %{workspace.context | deciding: {__MODULE__, :deciding, []}}}
        end)

      assert :ok = Answers.answer(press(key, "wardrik_link", "U2"), opts)
      assert_receive {:slack, _host, _path, %{"text" => text}}
      assert text =~ "The org's approvers, in its settings, name who else may."
    end

    test "says so once nothing waits on a connection", %{key: key} do
      :ok =
        Agent.decide(
          key,
          %{"call_1" => {:deny, "Not now."}},
          Wardrik.Token.root(Wardrik.Principal.new(:shell, "t"))
        )

      assert_receive {:resumed, %{"call_1" => {:deny, "Not now."}}}
      assert :ok = Answers.answer(press(key, "wardrik_link"), answering())

      assert_receive {:slack, _host, _path, %{"text" => text}}
      assert text == "That is no longer waiting on anyone to connect."
    end
  end

  describe "a press by whoever asked" do
    setup do
      key = Wardrik.Test.Fleet.id("slack-asker")

      {:ok, _pid} =
        Fleet.spawn(key,
          runner: {AgentRunners, :parking, [self(), "call_1"]},
          resumer: {AgentRunners, :resuming, [self(), {:ok, []}]}
        )

      on_exit(fn -> Fleet.forget(key) end)
      :ok = Event.Bus.subscribe(key, level: :lifecycle)

      asker =
        WardrikSlack.Test.installation()
        |> WardrikChannel.Member.new("U2")
        |> WardrikChannel.principal(name: "maria")

      :ok = Agent.ask(key, "Ship it.", sender: asker, host: Wardrik.Test.host())
      assert_receive %Event{payload: %Event.TurnParked{}}

      %{key: key}
    end

    test "decides their own turn's call, though they may not decide others'", %{key: key} do
      assert :ok = Answers.answer(press(key, "wardrik_approve", "U2"), answering())
      assert_receive {:resumed, %{"call_1" => :approve}}
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
      :ok = Agent.ask(key, "Ship it.", host: Wardrik.Test.host())
      assert_receive %Event{payload: %Event.TurnParked{}}

      %{key: key}
    end

    defp press(key, action, user \\ "U1", note \\ nil) do
      %{
        "state" => %{
          "values" => %{"wardrik-note:call_1" => %{"note" => %{"value" => note}}}
        },
        "type" => "block_actions",
        "user" => %{"id" => user, "username" => "jon"},
        "response_url" => "https://hooks.slack.com/actions/r",
        "message" => %{
          "blocks" => [
            %{"type" => "section"},
            %{"type" => "input", "block_id" => "wardrik-note:call_1"},
            %{"type" => "actions", "block_id" => "wardrik:call_1"}
          ]
        },
        "actions" => [
          %{
            "action_id" => action,
            "value" => JSON.encode!(%{a: to_string(key), c: "call_1", n: "deploy"})
          }
        ]
      }
    end

    test "approves the call, and says who did in place of the buttons", %{key: key} do
      assert :ok = Answers.answer(press(key, "wardrik_approve"), answering())

      assert_receive {:resumed, %{"call_1" => :approve}}

      jon = Wardrik.Principal.new(:channel, "slack/T1/U1", name: "jon")

      assert_receive %Event{
        payload: %Event.CallDecided{call_id: "call_1", decision: :approve, by: ^jon}
      }

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

    test "approves the call with what was written in its box, and says it in place of the box",
         %{key: key} do
      assert :ok =
               Answers.answer(
                 press(key, "wardrik_approve", "U1", " Only this once.\n"),
                 answering()
               )

      assert_receive {:resumed, %{"call_1" => {:approve, "Only this once."}}}

      assert_receive {:slack, _host, _path, reply}
      assert [%{"type" => "section"}, %{"type" => "context"} = line] = reply["blocks"]
      assert JSON.encode!(line) =~ "Approved `deploy`"
      assert JSON.encode!(line) =~ "Only this once."
    end

    test "approves without a note where the box is blank", %{key: key} do
      assert :ok = Answers.answer(press(key, "wardrik_approve", "U1", "  \n"), answering())
      assert_receive {:resumed, %{"call_1" => :approve}}
    end

    test "refuses someone who may not decide, or who holds nothing", %{key: key} do
      for user <- ["U2", "U3"] do
        assert :ok = Answers.answer(press(key, "wardrik_approve", user), answering())

        assert_receive {:slack, _host, _path, %{"response_type" => "ephemeral", "text" => text}}
        assert text =~ "approvers"
      end

      assert [{%{id: "call_1"}, _prompt}] = Agent.parked(key, host: Wardrik.Test.host())
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
