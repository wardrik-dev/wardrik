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
  def request(_request, _opts), do: %{status: 404, headers: %{}, body: ""}

  @impl Wardrik.Channel
  def notify(
        %Wardrik.Channel.Notification{workspace: workspace, room: room, notice: notice},
        opts
      ) do
    send(opts[:test], {:posted, opts[:channel], workspace, room, notice})
    :ok
  end
end

defmodule Wardrik.Test.Gives do
  @moduledoc "A resolver that gives every agent the notify targets it was given."
  @behaviour Wardrik.Resolver

  @impl Wardrik.Resolver
  def resolve(_request, notify), do: {:ok, %Wardrik.Resolved{notify: notify}}
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
      hook:
        {Wardrik.Notify.Webhook,
         url: "https://hooks.example.com/wardrik",
         secret: {:secret, "HOOK_SECRET"},
         req_options: [plug: {Req.Test, __MODULE__}]},
      ops: {Wardrik.Notify.Room, channel: "board", room: "#ops"}
    ]

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Authorizer, test: self()},
        resolver:
          {Wardrik.Test.Owned,
           {:"wardrik #{context.test}", channels: Map.get(context, :channels, %{"board" => "W1"})}},
        name: :"wardrik #{context.test}",
        store: store,
        vault_keys: [Wardrik.Vault.generate_key()],
        capabilities: [tools: Wardrik.Test.Tools],
        channels: [board: {Wardrik.Test.Board, test: self()}],
        notify: [targets: targets, retries: [attempts: 2, max_wait: 0]],
        defaults: Map.get(context, :defaults, %{})
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})

    :ok =
      seal(wardrik, {"deployment", "HOOK_SECRET"}, "shh", :signing_secret)

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = Wardrik.EventLog.subscribe(Wardrik.events(wardrik), :all)
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp define(scope, notify, fields \\ %{}, agent \\ "acme/triage") do
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

    Wardrik.run(scope, "agent.define", Map.put(definition, "agent", agent))
  end

  defp model(answer), do: stub(ReqLLM, :stream_text, fn _model, _messages, _opts -> answer end)

  defp ask(scope, agent \\ "acme/triage"),
    do: run!(scope, "agent.ask", %{"agent" => agent, "content" => "Go"})

  defp hooked do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:hooked, conn.host, Map.new(conn.req_headers), body})
      Plug.Conn.send_resp(conn, 204, "")
    end)
  end

  defp giving(wardrik, notify), do: %{wardrik | resolver: {Wardrik.Test.Gives, notify}}

  defp failed(agent \\ "acme/triage"),
    do: %Notice{agent: agent, kind: :failed, at: DateTime.utc_now(), reason: "x"}

  describe "routes" do
    test "reads a name, a list, and to and on" do
      assert Wardrik.Notify.route(%{"notify" => "ops"}) == %{to: ["ops"], on: [:parked, :failed]}
      assert Wardrik.Notify.route(%{"notify" => ["ops", "slack:#x"]}).to == ["ops", "slack:#x"]

      assert Wardrik.Notify.route(%{"notify" => %{"to" => "ops", "on" => ["finished"]}}) ==
               %{to: ["ops"], on: [:finished]}

      assert Wardrik.Notify.route(%{}) == nil
    end

    test "refuses a definition that routes nowhere here", %{
      scope: scope
    } do
      assert {:error, %Wardrik.Error{type: :invalid_request, message: nowhere}} =
               define(scope, "pager")

      assert nowhere =~ "no notify target pager"

      assert {:error, %Wardrik.Error{message: teams}} = define(scope, "teams:#ops")
      assert teams =~ "teams:#ops"

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

      # Defining checks the agent may use the deployment's target, as the agent's principal.
      asked =
        for {:authorize, %{action: action} = request} <-
              elem(Process.info(self(), :messages), 1),
            not String.ends_with?(action, ".use"),
            do: request

      assert asked != []
      assert Enum.all?(asked, &(&1.principal.id == "acme/@maria"))
      refute Enum.any?(asked, &(&1.principal.id == "wardrik:notify"))
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

    test "posts in a channel's room, in the workspace the agent's resolver gives", %{
      scope: scope
    } do
      model({:error, :boom})
      {:ok, _agent} = define(scope, ["board:#updates", "ops"])
      ask(scope)

      assert_receive {:posted, "board", "W1", "#updates", %Notice{kind: :failed}}
      assert_receive {:posted, "board", "W1", "#ops", %Notice{kind: :failed}}
    end

    @tag channels: %{"board" => "W2"}
    test "posts only in the workspace the resolver gives, never another", %{wardrik: wardrik} do
      assert Wardrik.Notify.deliver(wardrik, "board:#updates", failed()) == :ok
      assert_receive {:posted, "board", "W2", "#updates", %Notice{}}
      refute_received {:posted, "board", "W1", _room, _notice}
    end

    @tag channels: %{}
    test "skips a channel's room when the agent's resolver gives it no workspace there", %{
      wardrik: wardrik
    } do
      assert {:skip, why} = Wardrik.Notify.deliver(wardrik, "board:#updates", failed())
      assert why =~ "no workspace in board"
      assert {:skip, _why} = Wardrik.Notify.deliver(wardrik, "ops", failed())
      refute_received {:posted, _channel, _workspace, _room, _notice}
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

  describe "options" do
    test "refuses an option it doesn't take" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:target\]/, fn ->
        Wardrik.Notify.settings(target: [])
      end
    end

    test "checks each target's options as Wardrik starts, naming the target" do
      assert_raise ArgumentError,
                   ~r/notify target hook's options are invalid: unknown .*:uri/,
                   fn ->
                     Wardrik.Notify.settings(
                       targets: [hook: {Wardrik.Notify.Webhook, uri: "https://x.test"}]
                     )
                   end

      assert_raise ArgumentError,
                   ~r/notify target ops's options are invalid: required :room/,
                   fn ->
                     Wardrik.Notify.settings(
                       targets: [ops: {Wardrik.Notify.Room, channel: "board"}]
                     )
                   end

      assert_raise ArgumentError, ~r/target hook's/, fn ->
        Wardrik.Notify.settings(
          targets: [hook: {Wardrik.Notify.Webhook, url: "https://x.test", secret: {:vault, "X"}}]
        )
      end

      assert %{targets: %{"hook" => {Wardrik.Notify.Webhook, hook}, "ops" => {_room, ops}}} =
               Wardrik.Notify.settings(
                 targets: [
                   hook:
                     {Wardrik.Notify.Webhook,
                      url: "https://x.test", secret: {:secret, "HOOK_SECRET"}},
                   ops: {Wardrik.Notify.Room, channel: "board", room: "#ops"}
                 ]
               )

      assert hook[:secret] == {:secret, "HOOK_SECRET"} and hook[:req_options] == []
      assert ops == [channel: "board", room: "#ops"]
    end
  end

  describe "targets your app gives" do
    test "sends to the target the agent is resolved with, by its own options", %{
      wardrik: wardrik
    } do
      hooked()

      wardrik =
        giving(wardrik, %{
          "mine" => {Wardrik.Test.Told, test: self()},
          "hook" =>
            {Wardrik.Notify.Webhook,
             url: "https://hooks.acme.test/wardrik",
             secret: "acme-shh",
             req_options: [plug: {Req.Test, __MODULE__}]},
          "ops" => "ops"
        })

      assert :ok = Wardrik.Notify.deliver(wardrik, "mine", failed())
      assert_received {:told, "mine", %Notice{agent: "acme/triage"}}

      assert :ok = Wardrik.Notify.deliver(wardrik, "hook", failed())
      assert_received {:hooked, "hooks.acme.test", headers, body}
      assert headers["x-wardrik-signature"] == Wardrik.Notify.Webhook.sign("acme-shh", body)

      assert {:skip, _why} = Wardrik.Notify.deliver(wardrik, "audit", failed())
      refute_received {:told, "audit", _notice}

      route = %{"notify" => ["mine", "ops"]}
      {:ok, resolved} = Wardrik.Resolver.defined(wardrik, "acme/triage")
      assert Wardrik.Notify.check(wardrik, resolved.notify, route) == :ok

      assert {:error, %Wardrik.Error{}} =
               Wardrik.Notify.check(wardrik, resolved.notify, %{"notify" => "audit"})
    end

    test "refuses a target that doesn't fit its schema, or names a secret it would read", %{
      wardrik: wardrik
    } do
      for {target, why} <- [
            {{Wardrik.Notify.Webhook, uri: "https://x.test"}, ~r/unknown options \[:uri\]/},
            {{Wardrik.Notify.Webhook, url: "https://x.test", secret: {:secret, "HOOK_SECRET"}},
             ~r/its secret names a secret, which isn't read/},
            {{String, []}, ~r/String isn't a notify target/},
            {:hook, ~r/isn't a target's name or \{module, opts\}/}
          ] do
        assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
                 Wardrik.Resolver.defined(giving(wardrik, %{"hook" => target}), "acme/triage")

        assert message =~ why
      end
    end
  end
end
