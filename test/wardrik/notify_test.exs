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
  alias Wardrik.Statement

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
        egress: Map.get(context, :egress, &Wardrik.Egress.any/1),
        notify: [
          targets: targets,
          retries: [attempts: 2, max_wait: 0],
          req_options: [plug: {Req.Test, __MODULE__}]
        ],
        defaults: Map.get(context, :defaults, %{})
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})
    :ok = Wardrik.put_secret(wardrik, "deployment", "HOOK_SECRET", "shh", kind: :signing_secret)

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
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

  @doc "Refuses 10.0.0.5 alone, so the test needs no DNS."
  def public("https://10.0.0.5" <> _rest = url), do: {:error, "#{url} is a private address"}
  def public(_url), do: :ok

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

  defp target(owner, name, host, fields \\ %{}),
    do: Map.merge(%{"owner" => owner, "name" => name, "url" => "https://#{host}/wardrik"}, fields)

  defp listed(scope, owner) do
    %{"targets" => targets} = run!(scope, "notify_targets.list", %{"owner" => owner})
    Enum.map(targets, &{&1["owner"], &1["name"], &1["source"]})
  end

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
      assert other == "There's no notify target globex here, nor a channel that posts in it."

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
                      url: "https://x.test", secret: {:secret, "HOOK_SECRET"}, orgs: ["acme"]},
                   ops: {Wardrik.Notify.Room, channel: "board", room: "#ops"}
                 ]
               )

      assert hook[:secret] == {:secret, "HOOK_SECRET"} and hook[:req_options] == []
      assert ops[:approvers] == []
    end
  end

  describe "targets by owner" do
    test "adds, lists and removes an owner's webhooks, never answering a secret", %{
      wardrik: wardrik,
      scope: scope
    } do
      :ok = Wardrik.put_secret(wardrik, "acme", "OPS_SECRET", "acme-shh", kind: :signing_secret)

      assert run!(
               scope,
               "notify_targets.add",
               target("acme", "audit", "hooks.acme.test", %{"secret" => %{"name" => "OPS_SECRET"}})
             ) == %{
               "owner" => "acme",
               "name" => "audit",
               "source" => "runtime",
               "kind" => "webhook",
               "url" => "https://hooks.acme.test/wardrik",
               "secret" => %{"name" => "OPS_SECRET"}
             }

      run!(scope, "notify_targets.add", target("acme/@jon", "mine", "hooks.jon.test"))

      assert listed(scope, "acme/@jon") == [
               {"acme/@jon", "mine", "runtime"},
               {"acme", "audit", "runtime"},
               {"deployment", "hook", "config"},
               {"deployment", "ops", "config"}
             ]

      assert listed(scope, "globex") == [
               {"deployment", "audit", "config"},
               {"deployment", "globex", "config"},
               {"deployment", "hook", "config"},
               {"deployment", "ops", "config"}
             ]

      %{"targets" => targets} = run!(scope, "notify_targets.list", %{"owner" => "globex"})
      by_name = Map.new(targets, &{&1["name"], &1})

      assert by_name["hook"] == %{
               "owner" => "deployment",
               "name" => "hook",
               "source" => "config",
               "kind" => "webhook",
               "url" => "https://hooks.example.com/wardrik"
             }

      assert by_name["ops"] == %{
               "owner" => "deployment",
               "name" => "ops",
               "source" => "config",
               "kind" => "room"
             }

      assert by_name["audit"]["kind"] == "told"
      refute inspect(targets) =~ ~r/HOOK_SECRET|shh|maria|#ops/

      assert refused(scope, "notify_targets.add", target("acme", "audit", "x.test")) == :conflict

      assert refused(scope, "notify_targets.add", target("deployment", "ops", "x.test")) ==
               :conflict

      assert {:error,
              %Wardrik.Error{message: "acme holds no secret NOPE sealed as a signing_secret."}} =
               Wardrik.run(
                 scope,
                 "notify_targets.add",
                 target("acme", "other", "x.test", %{"secret" => %{"name" => "NOPE"}})
               )

      assert refused(scope, "notify_targets.add", target("acme", "x:y", "x.test")) ==
               :invalid_request

      assert refused(scope, "notify_targets.remove", %{"owner" => "globex", "target" => "audit"}) ==
               :not_found

      assert refused(scope, "notify_targets.remove", %{"owner" => "deployment", "target" => "ops"}) ==
               :invalid_request

      assert %{"owner" => "acme", "name" => "audit", "secret" => %{"name" => "OPS_SECRET"}} =
               run!(scope, "notify_targets.remove", %{"owner" => "acme", "target" => "audit"})

      assert {"deployment", "audit", "config"} in listed(scope, "acme")

      %{"events" => changes} = run!(scope, "audit.list", %{})

      assert for(%{"type" => "wardrik.notify_target." <> _ = type} <- changes, do: type) ==
               ~w(wardrik.notify_target.added wardrik.notify_target.added wardrik.notify_target.removed)

      assert {:ok, %Wardrik.NotifyTarget{owner: "acme/@jon", name: "mine", source: :runtime}} =
               Wardrik.NotifyTargets.remove(scope, "mine", owner: "acme/@jon")
    end

    test "routes an agent to its owner's target first, then its org's, then the deployment's", %{
      wardrik: wardrik,
      scope: scope
    } do
      hooked()
      model({:error, :boom})
      :ok = Wardrik.put_secret(wardrik, "acme", "OPS_SECRET", "acme-shh", kind: :signing_secret)

      run!(
        scope,
        "notify_targets.add",
        target("acme", "audit", "hooks.acme.test", %{"secret" => %{"name" => "OPS_SECRET"}})
      )

      {:ok, _agent} = define(scope, "audit", %{}, "acme/@jon/triage")
      ask(scope, "acme/@jon/triage")

      assert_receive {:hooked, "hooks.acme.test", headers, body}
      assert headers["x-wardrik-signature"] == Wardrik.Notify.Webhook.sign("acme-shh", body)
      assert %{"agent" => "acme/@jon/triage", "event" => "turn_failed"} = JSON.decode!(body)
      refute_received {:told, "audit", _notice}

      run!(scope, "notify_targets.add", target("acme/@jon", "audit", "hooks.jon.test"))
      ask(scope, "acme/@jon/triage")

      assert_receive {:hooked, "hooks.jon.test", headers, _body}
      refute Map.has_key?(headers, "x-wardrik-signature")

      {:ok, _agent} = define(scope, "audit", %{}, "globex/triage")
      ask(scope, "globex/triage")
      assert_receive {:told, "audit", %Notice{agent: "globex/triage"}}
    end

    test "refuses a route to another owner's target", %{scope: scope} do
      run!(scope, "notify_targets.add", target("globex", "pager", "hooks.globex.test"))
      run!(scope, "notify_targets.add", target("acme/@maria", "mine", "hooks.maria.test"))

      assert {:error, %Wardrik.Error{message: "There's no notify target pager" <> _}} =
               define(scope, "pager")

      assert {:error, %Wardrik.Error{}} = define(scope, "mine", %{}, "acme/@jon/triage")
      assert {:ok, _agent} = define(scope, "mine", %{}, "acme/@maria/triage")
      assert {:ok, _agent} = define(scope, "pager", %{}, "globex/triage")
    end

    @tag egress: &Wardrik.NotifyTest.public/1
    test "checks a webhook's URL as it's added and as each notice is sent, following no redirect",
         %{wardrik: wardrik, scope: scope} do
      refusing = %{wardrik | egress: fn url -> {:error, "#{url} is a private address"} end}

      assert {:error,
              %Wardrik.Error{
                type: :invalid_request,
                message:
                  "The target can't be reached: https://10.0.0.5/wardrik is a private address."
              }} =
               Wardrik.run(
                 scope,
                 "notify_targets.add",
                 target("acme", "inside", "10.0.0.5")
               )

      run!(scope, "notify_targets.add", target("acme", "moved", "hooks.acme.test"))
      notice = %Notice{agent: "acme/triage", kind: :failed, at: DateTime.utc_now(), reason: "x"}

      assert {:skip, "but it can't be reached: https://hooks.acme.test/wardrik is a private" <> _} =
               Wardrik.Notify.deliver(refusing, "moved", notice)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert Wardrik.Notify.deliver(wardrik, "moved", notice) == {:error, {:status, 302}}
    end

    test "skips a webhook whose owner no longer holds its secret", %{
      wardrik: wardrik,
      scope: scope
    } do
      :ok = Wardrik.put_secret(wardrik, "acme", "OPS_SECRET", "acme-shh", kind: :signing_secret)

      run!(
        scope,
        "notify_targets.add",
        target("acme", "signed", "hooks.acme.test", %{"secret" => %{"name" => "OPS_SECRET"}})
      )

      :ok = Wardrik.delete_secret(wardrik, "acme", "OPS_SECRET")
      notice = %Notice{agent: "acme/triage", kind: :failed, at: DateTime.utc_now(), reason: "x"}

      assert Wardrik.Notify.deliver(wardrik, "signed", notice) ==
               {:skip, "but acme holds no secret OPS_SECRET to sign it with"}
    end

    test "lets a reader list, and a definer add and remove their own", %{wardrik: wardrik} do
      grant =
        &Wardrik.as(wardrik, "acme/@maria", [
          Statement.new(roles: &1, resources: ["acme/@maria/*"])
        ])

      reader = grant.([:reader])
      definer = grant.([:reader, :definer])
      mine = target("acme/@maria", "mine", "hooks.maria.test")

      assert [{"deployment", "audit", "config"} | _rest] = listed(reader, "acme/@maria")
      assert refused(reader, "notify_targets.add", mine) == :forbidden
      assert refused(reader, "notify_targets.list", %{"owner" => "acme"}) == :not_found

      assert %{"name" => "mine"} = run!(definer, "notify_targets.add", mine)

      assert refused(reader, "notify_targets.remove", %{
               "owner" => "acme/@maria",
               "target" => "mine"
             }) ==
               :forbidden

      assert %{"name" => "mine"} =
               run!(definer, "notify_targets.remove", %{
                 "owner" => "acme/@maria",
                 "target" => "mine"
               })

      assert refused(definer, "notify_targets.add", target("acme", "ops", "x.test")) == :not_found
    end
  end
end
