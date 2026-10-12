defmodule Wardrik.Event.CodecTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Wardrik.Agent.Message
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Audit
  alias Wardrik.Event
  alias Wardrik.Event.Codec
  alias Wardrik.Event.Source
  alias Wardrik.Grant
  alias Wardrik.Principal

  @schemas WardrikProtocol.dir()
  @agent Wardrik.AgentID.parse!("acme/@ops/triage")

  defp read(name), do: @schemas |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()

  defp build(name), do: JSV.build!(read(name), resolver: WardrikProtocol.Resolver)

  defp turn, do: Source.root(@agent, name: "turn")
  defp within(source, name), do: Source.child(source, name: name)

  defp call(id, name), do: %{id: id, name: name, arguments: %{"repo" => "wardrik"}}

  defp response(message, usage \\ %{input_tokens: 12, output_tokens: 4, cached_tokens: 3}) do
    %ReqLLM.Response{
      id: "resp_1",
      model: "claude-sonnet-5",
      context: nil,
      message: message,
      usage: usage,
      finish_reason: :stop
    }
  end

  # One payload of every shape `Wardrik.Event.payload/0` lists, with the source
  # each is emitted on.
  defp fixtures do
    turn = turn()
    tool = within(turn, "deploy")
    step = within(turn, "research")
    by = Principal.new(:slack, "U1", name: "jon")

    asking =
      Context.assistant("",
        tool_calls: [ReqLLM.ToolCall.new("call_1", "deploy", ~s({"repo":"wardrik"}))]
      )

    [
      {turn, {:turn_started, [Message.new("Ship it.", "m-1")]}},
      {turn,
       {:turn_finished,
        [asking, Context.tool_result("call_1", "deploy", "done"), Context.assistant("Shipped.")]}},
      {turn, {:turn_failed, :timeout}},
      {turn, {:turn_interrupted, %{dropped: 1, kept: 0, resolution: :killed, elapsed_ms: 2_000}}},
      {turn,
       {:turn_parked,
        [
          {call("call_1", "deploy"), "This ships to production."},
          {call("call_2", "refund") |> Map.put(:in_doubt, true) |> Map.put(:labels, ["outside"]),
           "refund may already have run."}
        ]}},
      {turn, {:turn_resumed, %{"call_1" => :approve}}},
      {turn, {:call_decided, "call_1", {:deny, "Not today."}, by}},
      {Source.root(@agent), {:message_queued, Message.new("Ship it.", "m-1", sender: by)}},
      {Source.root(@agent), {:agent_started, :wardrik_b@localhost, :parked, "9f2c1e7a"}},
      {Source.root(@agent), {:agent_stopped, :wardrik_b@localhost, :idle}},
      {turn,
       {:context_compacted,
        %{messages_before: 40, messages_after: 8, tokens_before: 60_000, tokens_after: 9_000}}},
      {Source.root(@agent), {:context_cleared, 12}},
      {Source.root(@agent), {:schedule_fired, "sweep", :asked}},
      {step, {:span_started, "research"}},
      {step, {:span_finished, {:error, :timeout}, 1_200}},
      {step, {:delegation_started, "Look into the failing build."}},
      {step, {:delegation_finished, {:ok, "It was a flaky test."}, 9_000}},
      {turn,
       {:model_started, "#{turn.trace.span_id}.m0", "anthropic:claude-sonnet-5",
        %{by: :default, hooks: []}}},
      {turn, {:model_finished, "#{turn.trace.span_id}.m0", :ok, 1_500, response(asking), nil}},
      {turn, {:result, "Shipped"}},
      {turn, {:thinking, "The build is green."}},
      {turn, {:meta, %{usage: %{input_tokens: 1}}}},
      {turn, {:chunk, :anything}},
      {turn, {:tool_call, %{name: "deploy"}}},
      {turn, {:deadline_reached, 6}},
      {tool,
       {:tool_started, "call_1", "deploy", %{"repo" => "wardrik"}, "acme/@ops/triage/t/call_1",
        %{by: :hook, hooks: ["careful"]}}},
      {tool,
       {:tool_finished, "call_1", "deploy",
        {:ok, %{"ok" => true, "result" => %{"url" => "https://example.com/1"}}},
        %{id: "w1", name: "deploys"}, nil}},
      {tool, {:tool_replayed, "call_1", "deploy", {:ok, %{"ok" => true, "result" => "done"}}}},
      {tool,
       {:tool_denied, "call_1", "deploy", "Not today.", %{by: :person, hooks: ["careful"]}}},
      {tool, {:tool_parked, "call_1", "deploy", "This ships to production."}},
      {tool, {:tool_progress, "call_1", "deploy", 3, 10}}
    ]
  end

  # One change of every shape `Audit.action/0` lists.
  defp changes do
    id = @agent
    prefix = Prefix.new!(org: "acme")
    {:ok, grant} = Grant.new(prefix, [:read, :define])

    [
      {:agent_defined, id},
      {:agent_spawned, id, :wardrik_b@localhost},
      {:agent_stopped, id},
      {:agent_forgotten, id},
      {:agent_moved, id, :wardrik_b@localhost},
      {:agent_cancelled, id},
      {:agents_cancelled, prefix, 3},
      {:agent_cleared, id},
      {:schedule_set, id, "sweep"},
      {:schedule_removed, id, "sweep"},
      {:agents_reloaded, [:wardrik_a@localhost, :wardrik_b@localhost]},
      {:room_bound, "slack", "C0123", id, :mentions},
      {:room_unbound, "slack", "C0123"},
      {:token_created, "tok_1", "ci", grant, Principal.new(:user, "jon")},
      {:token_revoked, "tok_1"},
      {:secret_stored, "GITHUB_TOKEN", Prefix.all()},
      {:secret_removed, "GITHUB_TOKEN", Prefix.new!(org: "acme", user: "jon")}
    ]
  end

  # The first element of every tuple a union type of `module` lists.
  defp tags(module, name) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    {:type, {^name, {:type, _, :union, members}, []}} =
      Enum.find(types, &match?({:type, {^name, _, _}}, &1))

    for {:type, _, :tuple, [{:atom, _, tag} | _]} <- members, do: tag
  end

  defp valid!(event) do
    assert {:ok, _} = JSV.validate(event, build("cloudevent")), "envelope of #{event["type"]}"

    "wardrik." <> type = event["type"]
    data = JSV.validate(event["data"], build(type))
    assert {:ok, _} = data, "#{type}: #{inspect(data)}"

    assert event == event |> JSON.encode!() |> JSON.decode!()
  end

  defp encode(source, payload, opts \\ [sequence: 41, message_id: "m0"]),
    do: Codec.encode(Event.new(source, payload), opts)

  describe "every payload" do
    test "has a fixture here" do
      assert Enum.sort(tags(Event, :payload)) ==
               Enum.sort(Enum.map(fixtures(), &elem(elem(&1, 1), 0)))
    end

    test "encodes to a CloudEvent the envelope schema takes, with data its type's schema takes" do
      for {source, payload} <- fixtures(),
          {:ok, event} <- [encode(source, payload)],
          do: valid!(event)
    end
  end

  describe "every change" do
    test "has a fixture here" do
      assert Enum.sort(tags(Audit, :action)) ==
               Enum.sort(Enum.map(changes(), &elem(&1, 0)))
    end

    test "encodes to a CloudEvent the envelope schema takes, with data its type's schema takes" do
      by = Principal.new(:shell, "jon")

      for action <- changes(), anyone <- [by, nil] do
        assert {:ok, event} = Codec.encode(Audit.new(action, anyone), sequence: 7)
        valid!(event)
      end
    end

    test "comes from the audit, at the root of a trace of its own, and names who made it" do
      by = Principal.new(:token, "tok_9", name: "ci")
      audit = Audit.new({:agent_forgotten, @agent}, by)

      assert {:ok, event} = Codec.encode(audit, sequence: 7)

      assert %{
               "id" => id,
               "source" => "wardrik://local/audit",
               "type" => "wardrik.agent.forgotten",
               "subject" => "agents/acme/@ops/triage",
               "sequence" => "000000000007",
               "data" => %{
                 "agent" => %{"id" => "acme/@ops/triage"},
                 "actor" => %{"type" => "token", "id" => "tok_9", "name" => "ci"}
               }
             } = event

      assert id == audit.id
      assert event["traceparent"] == "00-#{audit.trace.trace_id}-#{audit.trace.span_id}-01"
      refute Map.has_key?(event, "parentspanid")
    end

    test "says nothing of an actor none is known for, or the owner of a deployment's secret" do
      all = Prefix.all()

      assert {:ok, %{"data" => data}} =
               Codec.encode(Audit.new({:secret_stored, "KEY", all}, nil))

      assert data == %{"secret" => %{"name" => "KEY"}}

      jon = Prefix.new!(org: "acme", user: "jon")

      assert {:ok, %{"data" => %{"owner" => "acme/@jon/"}}} =
               Codec.encode(Audit.new({:secret_removed, "KEY", jon}, nil))
    end
  end

  describe "the envelope" do
    test "carries the event's id, its agent, its time and its span" do
      source = within(turn(), "deploy")

      event =
        Event.new(source, {:tool_denied, "call_1", "deploy", "No.", %{by: :default, hooks: []}})

      assert {:ok, cloud_event} = Codec.encode(event, sequence: 41)

      assert %{
               "specversion" => "1.0",
               "type" => "wardrik.tool_call.denied",
               "subject" => "tool_calls/call_1",
               "source" => "wardrik://local/agents/acme/@ops/triage",
               "dataschema" => "urn:wardrik:schema:v1:tool_call.denied",
               "sequence" => "000000000041"
             } = cloud_event

      assert cloud_event["id"] == event.id

      assert cloud_event["traceparent"] ==
               "00-#{source.trace.trace_id}-#{source.trace.span_id}-01"

      assert cloud_event["parentspanid"] == source.trace.parent_span_id
      assert {:ok, _time, 0} = DateTime.from_iso8601(cloud_event["time"])
    end

    test "has no sequence where none was given, and no parent at a run's root" do
      assert {:ok, event} = encode(turn(), {:turn_resumed, %{}}, [])

      refute Map.has_key?(event, "sequence")
      refute Map.has_key?(event, "parentspanid")
    end

    test "names the log it came from" do
      assert Codec.source(@agent) == "wardrik://local/agents/acme/@ops/triage"
      assert Codec.source(:audit) == "wardrik://local/audit"
    end
  end

  describe "durable and live" do
    test "deltas and progress are live, everything sent otherwise durable" do
      refute Codec.durable?(:result)
      refute Codec.durable?(:thinking)
      refute Codec.durable?(:tool_progress)
      assert Codec.durable?(:tool_started)
      assert Codec.durable?(:turn_parked)
    end

    test "provider records and the per-call park are not sent" do
      for payload <- [{:chunk, 1}, {:meta, %{}}, {:tool_call, %{}}, {:tool_parked, "c", "n", "p"}],
          do: assert(:skip = encode(turn(), payload))
    end
  end

  describe "tool calls" do
    defp completed(result),
      do: elem(encode(turn(), {:tool_finished, "call_1", "deploy", result, nil, nil}), 1)["data"]

    test "answer with what the tool returned, whichever way it said it" do
      assert %{"status" => "ok", "tool" => %{"call" => %{"result" => %{"n" => 1}}}} =
               completed({:ok, %{"ok" => true, "result" => %{n: 1}}})

      assert %{"status" => "ok", "tool" => %{"call" => %{"result" => ["a", "tuple"]}}} =
               completed({:ok, {:a, :tuple}})

      assert %{"status" => "error", "error" => %{"type" => "denied", "message" => "No."}} =
               completed(Wardrik.Tool.Result.error(:denied, "No."))

      assert %{"status" => "error", "error" => %{"type" => "timeout"}} =
               completed({:error, :timeout})
    end

    test "cut a result too long to keep, and say so" do
      %{"tool" => %{"call" => call}} =
        completed({:ok, %{"ok" => true, "result" => String.duplicate("x", 70_000)}})

      assert call["truncated"] == true
      assert byte_size(call["result"]) == 64 * 1024
    end

    test "start with the arguments and the key a tool passes on" do
      {:ok, %{"data" => data}} =
        encode(
          turn(),
          {:tool_started, "call_1", "deploy", %{repo: :wardrik}, "key-1",
           %{by: :default, hooks: []}}
        )

      assert data["tool"]["call"] == %{
               "id" => "call_1",
               "arguments" => %{"repo" => "wardrik"},
               "idempotency_key" => "key-1"
             }
    end

    test "name who decided them, and what answered them" do
      {:ok, %{"data" => started}} =
        encode(turn(), {:tool_started, "call_1", "deploy", %{}, "k", %{by: :default, hooks: []}})

      assert started["decided"] == %{"by" => "default"}

      {:ok, %{"data" => denied}} =
        encode(
          turn(),
          {:tool_denied, "call_1", "deploy", "No.", %{by: :hook, hooks: ["careful"]}}
        )

      assert denied["decided"] == %{"by" => "hook", "hooks" => ["careful"]}

      {:ok, %{"data" => finished}} =
        encode(
          turn(),
          {:tool_finished, "call_1", "deploy", {:ok, 1}, %{id: "w1", name: "deploys"}, nil}
        )

      assert finished["served_by"] == %{"id" => "w1", "name" => "deploys"}

      {:ok, %{"data" => unserved}} =
        encode(turn(), {:tool_finished, "call_1", "deploy", {:ok, 1}, nil, nil})

      refute Map.has_key?(unserved, "served_by")
    end

    test "carry what a call cost where its tool said, and nothing otherwise" do
      {:ok, %{"data" => priced} = event} =
        encode(
          turn(),
          {:tool_finished, "call_1", "search", {:ok, 1}, nil, %{micro_usd: 4_000, source: :tool}}
        )

      valid!(event)
      assert priced["cost"] == %{"micro_usd" => 4_000, "source" => "tool"}
      refute Map.has_key?(completed({:ok, 1}), "cost")
    end

    test "answered from the ledger say they were replayed" do
      {:ok, %{"data" => data}} =
        encode(
          turn(),
          {:tool_replayed, "call_1", "deploy", {:ok, %{"ok" => true, "result" => 1}}}
        )

      assert data["replayed"] == true
    end
  end

  describe "assistant messages" do
    test "complete with the message, the response and its usage" do
      message =
        Context.assistant("",
          tool_calls: [ReqLLM.ToolCall.new("call_1", "deploy", ~s({"repo":"wardrik"}))]
        )

      {:ok, %{"data" => data}} =
        encode(turn(), {:model_finished, "s.m0", :ok, 900, response(message), nil})

      assert data["message"] == %{
               "id" => "s.m0",
               "role" => "assistant",
               "parts" => [
                 %{
                   "type" => "tool_call",
                   "id" => "call_1",
                   "name" => "deploy",
                   "arguments" => %{"repo" => "wardrik"}
                 }
               ]
             }

      assert data["response"] == %{
               "model" => "claude-sonnet-5",
               "id" => "resp_1",
               "finish_reasons" => ["stop"]
             }

      assert data["usage"] == %{
               "input_tokens" => 12,
               "output_tokens" => 4,
               "cache_read" => %{"input_tokens" => 3}
             }

      assert data["status"] == "ok"
    end

    test "complete with what the call cost, null where nobody prices the model" do
      message = Context.assistant("hi")

      {:ok, %{"data" => priced} = event} =
        encode(
          turn(),
          {:model_finished, "s.m0", :ok, 900, response(message),
           %{micro_usd: 4_200, source: :catalog}}
        )

      valid!(event)
      assert priced["cost"] == %{"micro_usd" => 4_200, "source" => "catalog"}

      {:ok, %{"data" => unpriced} = event} =
        encode(turn(), {:model_finished, "s.m0", :ok, 900, response(message), nil})

      valid!(event)

      assert Map.fetch(unpriced, "cost") == {:ok, nil}
    end

    test "that were stopped say so, and name their message alone" do
      {:ok, %{"data" => data}} =
        encode(turn(), {:model_finished, "s.m0", {:error, :interrupted}, 10, nil, nil})

      assert data == %{
               "message" => %{"id" => "s.m0"},
               "status" => "cancelled",
               "duration_ms" => 10
             }
    end

    test "start with the provider and model asked" do
      {:ok, %{"data" => data}} =
        encode(
          turn(),
          {:model_started, "s.m0", {:anthropic, model: "claude-sonnet-5"},
           %{by: :default, hooks: []}}
        )

      assert data["provider"] == %{"name" => "anthropic"}
      assert data["request"] == %{"model" => "claude-sonnet-5"}
    end

    test "stream as deltas under the message they belong to" do
      {:ok, event} = encode(turn(), {:result, "Ship"}, message_id: "s.m0")

      assert event["type"] == "wardrik.message.delta"
      assert event["data"] == %{"message" => %{"id" => "s.m0"}, "delta" => "Ship"}
    end

    test "answered by a tool name the call they answer" do
      {:ok, %{"data" => %{"messages" => [message]}}} =
        encode(turn(), {:turn_finished, [Context.tool_result("call_1", "deploy", "done")]})

      assert message["parts"] == [
               %{"type" => "tool_call_response", "id" => "call_1", "response" => "done"}
             ]
    end
  end

  describe "interrupts" do
    test "say whether a tool or the model call is waiting, and on what" do
      model = %{id: "model_1", name: "model", arguments: %{}}
      doubt = Map.put(call("call_2", "refund"), :in_doubt, true)

      {:ok, %{"data" => data}} =
        encode(
          turn(),
          {:turn_parked,
           [{call("call_1", "deploy"), "Ship?"}, {model, "Over budget."}, {doubt, "Again?"}]}
        )

      assert data["interrupts"] == [
               %{
                 "id" => "call_1",
                 "reason" => "tool_approval",
                 "message" => "Ship?",
                 "tool_call_id" => "call_1"
               },
               %{"id" => "model_1", "reason" => "model_approval", "message" => "Over budget."},
               %{
                 "id" => "call_2",
                 "reason" => "in_doubt",
                 "message" => "Again?",
                 "tool_call_id" => "call_2"
               }
             ]
    end

    test "say what the run had read, which may be what asked for them" do
      labelled = Map.put(call("call_1", "deploy"), :labels, ["outside"])

      {:ok, %{"data" => data}} = encode(turn(), {:turn_parked, [{labelled, "Ship?"}]})

      assert [%{"labels" => ["outside"]}] = data["interrupts"]
    end

    test "are resolved by someone, approving or rejecting" do
      {:ok, %{"data" => approved}} = encode(turn(), {:call_decided, "call_1", :approve, nil})
      assert approved == %{"interrupt" => %{"id" => "call_1"}, "decision" => "approved"}

      by = Principal.new(:shell, "wardrik")
      {:ok, %{"data" => rejected}} = encode(turn(), {:call_decided, "call_1", {:deny, "No."}, by})

      assert rejected["decision"] == "rejected"
      assert rejected["reason"] == "No."
      assert rejected["resolved_by"] == %{"type" => "shell", "id" => "wardrik"}

      {:ok, %{"data" => noted}} =
        encode(turn(), {:call_decided, "call_1", {:approve, " Only once. "}, by})

      assert noted["decision"] == "approved"
      assert noted["note"] == "Only once."
      refute Map.has_key?(noted, "reason")

      {:ok, %{"data" => blank}} = encode(turn(), {:call_decided, "call_1", {:approve, " "}, nil})
      assert blank == %{"interrupt" => %{"id" => "call_1"}, "decision" => "approved"}
    end
  end

  test "a message created names who sent it, where anyone is named" do
    by = Principal.new(:slack, "U1", name: "jon")

    assert {:ok, %{"data" => %{"sender" => %{"type" => "slack", "id" => "U1", "name" => "jon"}}}} =
             encode(Source.root(@agent), {:message_queued, Message.new("Hi.", "m-1", sender: by)})

    assert {:ok, %{"data" => data}} =
             encode(Source.root(@agent), {:message_queued, Message.new("Hi.", "m-1")})

    refute Map.has_key?(data, "sender")
  end

  test "a run names the messages it answers" do
    {:ok, event} =
      encode(turn(), {:turn_started, [Message.new("one", "m-1"), Message.new("two", "m-2")]})

    assert event["data"]["run"]["message_ids"] == ["m-1", "m-2"]
    assert event["subject"] == "runs/" <> event["data"]["run"]["id"]
  end

  describe "steps and subagents" do
    test "a subagent that failed says why" do
      {:ok, event} =
        encode(within(turn(), "research"), {:delegation_finished, {:error, :timeout}, 5})

      assert event["type"] == "wardrik.subagent.failed"
      assert event["data"]["error"]["type"] == "timeout"
      assert event["data"]["agent"] == %{"name" => "research"}
    end

    test "a step that finished says so" do
      {:ok, event} = encode(within(turn(), "plan"), {:span_finished, :ok, 5})

      assert event["data"] == %{"status" => "ok", "duration_ms" => 5}
    end

    test "a step a stopped turn interrupted is cancelled" do
      {:ok, event} = encode(within(turn(), "plan"), {:span_finished, {:error, :interrupted}, 5})

      assert event["data"] == %{"status" => "cancelled", "duration_ms" => 5}
      assert {:ok, _} = JSV.validate(event["data"], build("step.completed"))
    end
  end

  test "a model is read from however it was named" do
    started = fn spec ->
      {:ok, %{"data" => data}} =
        encode(turn(), {:model_started, "s.m0", spec, %{by: :default, hooks: []}})

      {data["provider"], data["request"]["model"]}
    end

    assert started.("claude-sonnet-5") == {nil, "claude-sonnet-5"}
    assert started.(%{provider: :openai, id: "gpt-5"}) == {%{"name" => "openai"}, "gpt-5"}
    assert started.(:odd) == {nil, ":odd"}
  end
end
