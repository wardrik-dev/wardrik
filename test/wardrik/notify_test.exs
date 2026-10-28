defmodule Wardrik.Test.Told do
  @moduledoc "A notify target that tells the test each notice, and answers what the test set."
  @behaviour Wardrik.Notify

  @impl Wardrik.Notify
  def deliver(notice, opts) do
    send(opts[:test], {:told, opts[:target], notice})
    answer(opts[:answers])
  end

  defp answer(nil), do: :ok
  defp answer(answers), do: Agent.get_and_update(answers, fn [next | rest] -> {next, rest} end)
end

defmodule Wardrik.Test.Board do
  @moduledoc "A channel that tells the test each notice posted in a room."
  @behaviour Wardrik.Channel

  @impl Wardrik.Channel
  def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> nil end]}}

  @impl Wardrik.Channel
  def request(_opts, _request), do: %{status: 404, headers: %{}, body: ""}

  @impl Wardrik.Channel
  def notify(opts, room, notice, approvers) do
    send(opts[:test], {:posted, opts[:channel], room, notice, approvers})
    :ok
  end
end

defmodule Wardrik.NotifyTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Notice

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global
  setup {Req.Test, :set_req_test_to_shared}

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")
    {:ok, answers} = Agent.start_link(fn -> Map.get(context, :answers, []) end)

    targets = [
      audit: {Wardrik.Test.Told, test: self(), answers: context[:answers] && answers},
      globex: {Wardrik.Test.Told, test: self(), orgs: ["globex"]},
      hook:
        {Wardrik.Notify.Webhook,
         url: "https://hooks.example.com/wardrik",
         secret: {:secret, "HOOK_SECRET"},
         req_options: [plug: {Req.Test, __MODULE__}]},
      ops: {Wardrik.Notify.Room, channel: "board", room: "#ops", approvers: ["@maria"]}
    ]

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        keys: [WardrikVault.generate_key()],
        capabilities: [tools: Wardrik.Test.Tools],
        channels: [board: {Wardrik.Test.Board, test: self()}],
        notify: [targets: targets, retries: [attempts: 2, max_wait: 0]],
        defaults: Map.get(context, :defaults, %{})
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})
    :ok = Wardrik.put_secret(wardrik, "deployment", "HOOK_SECRET", "shh")

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp define(scope, notify, fields \\ %{}) do
    definition =
      Map.merge(
        %{
          "model" => @model,
          "tools" => ["tools"],
          "policy" => %{"ask" => ["echo"]},
          "notify" => notify
        },
        fields
      )

    Wardrik.run(scope, "agent.define", Map.put(definition, "agent", "acme/triage"))
  end

  defp model(answer), do: stub(ReqLLM, :stream_text, fn _model, _messages, _opts -> answer end)

  defp ask(scope), do: run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Go"})

  describe "routes" do
    test "reads a name, a list, and to and on" do
      assert Wardrik.Notify.route(%{"notify" => "ops"}) == %{to: ["ops"], on: [:parked, :failed]}
      assert Wardrik.Notify.route(%{"notify" => ["ops", "slack:#x"]}).to == ["ops", "slack:#x"]

      assert Wardrik.Notify.route(%{"notify" => %{"to" => "ops", "on" => ["finished"]}}) ==
               %{to: ["ops"], on: [:finished]}

      assert Wardrik.Notify.route(%{}) == nil
    end

    test "refuses a definition that routes nowhere here, or to another org's target", %{
      scope: scope
    } do
      assert {:error, %Wardrik.Error{type: :invalid_request, message: nowhere}} =
               define(scope, "pager")

      assert nowhere =~ "no notify target pager"

      assert {:error, %Wardrik.Error{message: teams}} = define(scope, "teams:#ops")
      assert teams =~ "teams:#ops"

      assert {:error, %Wardrik.Error{message: other}} = define(scope, "globex")
      assert other =~ "doesn't tell acme's agents"

      assert {:ok, _agent} = define(scope, ["audit", "board:#updates"])
    end
  end

  describe "notices" do
    test "tells of a turn that waits on a person, with each call's arguments", %{scope: scope} do
      model({:ok, calling([call("call_1", "echo", %{text: "hi"})])})
      {:ok, _agent} = define(scope, "audit")
      ask(scope)

      assert_receive {:told, "audit", %Notice{kind: :parked, agent: "acme/triage", calls: [call]}}
      assert %{interrupt: %Wardrik.Interrupt{name: "echo"}, arguments: %{"text" => "hi"}} = call
    end

    test "tells of a turn that failed", %{scope: scope} do
      model({:error, :boom})
      {:ok, _agent} = define(scope, "audit")
      ask(scope)

      assert_receive {:told, "audit", %Notice{kind: :failed, reason: reason}}
      assert is_binary(reason)
    end

    test "tells what a turn answered only where on asks for it", %{scope: scope} do
      model({:ok, answer("All quiet.")})
      {:ok, _agent} = define(scope, "audit")
      ask(scope)
      until("wardrik.run.completed")
      refute_received {:told, _target, _notice}

      {:ok, _agent} = define(scope, %{"to" => "audit", "on" => ["finished"]})
      ask(scope)

      assert_receive {:told, "audit", %Notice{kind: :finished, text: "All quiet."}}
    end

    @tag defaults: %{"notify" => "audit"}
    test "routes as the defaults say, where a definition says nothing", %{scope: scope} do
      model({:error, :boom})

      {:ok, _agent} =
        Wardrik.run(scope, "agent.define", %{"agent" => "acme/triage", "model" => @model})

      ask(scope)

      assert_receive {:told, "audit", %Notice{kind: :failed, agent: "acme/triage"}}
    end

    @tag answers: [{:error, :down}, :ok]
    test "tries a failed delivery again", %{scope: scope} do
      model({:error, :boom})
      {:ok, _agent} = define(scope, "audit")
      ask(scope)

      assert_receive {:told, "audit", %Notice{kind: :failed}}
      assert_receive {:told, "audit", %Notice{kind: :failed}}
    end

    test "posts in a channel's room, asking a target's approvers", %{scope: scope} do
      model({:error, :boom})
      {:ok, _agent} = define(scope, ["board:#updates", "ops"])
      ask(scope)

      assert_receive {:posted, "board", "#updates", %Notice{kind: :failed}, []}
      assert_receive {:posted, "board", "#ops", %Notice{kind: :failed}, ["@maria"]}
    end

    test "posts signed JSON to a webhook", %{scope: scope} do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:hooked, Map.new(conn.req_headers), body})
        Plug.Conn.send_resp(conn, 204, "")
      end)

      model({:error, :boom})
      {:ok, _agent} = define(scope, "hook")
      ask(scope)

      assert_receive {:hooked, headers, body}
      assert headers["x-wardrik-event"] == "turn_failed"
      assert headers["x-wardrik-signature"] == Wardrik.Notify.Webhook.sign("shh", body)

      assert %{"event" => "turn_failed", "agent" => "acme/triage", "calls" => [], "text" => nil} =
               JSON.decode!(body)
    end

    test "sends a parked turn's calls to a webhook, and tries again an answer other than 2xx", %{
      scope: scope
    } do
      test = self()
      {:ok, statuses} = Agent.start_link(fn -> [500, 200] end)

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        status = Agent.get_and_update(statuses, fn [next | rest] -> {next, rest} end)
        send(test, {:hooked, status, JSON.decode!(body)})
        Plug.Conn.send_resp(conn, status, "")
      end)

      model({:ok, calling([call("call_1", "echo", %{text: "hi"})])})
      {:ok, _agent} = define(scope, "hook")
      ask(scope)

      assert_receive {:hooked, 500, _body}
      assert_receive {:hooked, 200, %{"event" => "turn_parked", "calls" => [call]}}

      assert %{
               "name" => "echo",
               "arguments" => %{"text" => "hi"},
               "authorization" => false,
               "labels" => []
             } = call
    end
  end
end
