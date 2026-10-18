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
  alias Wardrik.Servers.Key

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
    by = Principal.new(:channel, "slack/U1", name: "jon")

    asking =
      Context.assistant("",
        tool_calls: [ReqLLM.ToolCall.new("call_1", "deploy", ~s({"repo":"wardrik"}))]
      )

    [
      {turn, %Event.TurnStarted{messages: [Message.new("Ship it.", "m-1")]}},
      {turn,
       %Event.TurnFinished{
         messages: [
           asking,
           Context.tool_result("call_1", "deploy", "done"),
           Context.assistant("Shipped.")
         ]
       }},
      {turn, %Event.TurnFailed{reason: :timeout}},
      {turn,
       %Event.TurnInterrupted{
         stats: %{dropped: 1, kept: 0, resolution: :killed, elapsed_ms: 2_000}
       }},
      {turn,
       %Event.TurnParked{
         calls: [
           {call("call_1", "deploy"), "This ships to production."},
           {call("call_2", "refund") |> Map.put(:in_doubt, true) |> Map.put(:labels, ["outside"]),
            "refund may already have run."}
         ]
       }},
      {turn, %Event.TurnResumed{decisions: %{"call_1" => :approve}}},
      {turn, %Event.CallDecided{call_id: "call_1", decision: {:deny, "Not today."}, by: by}},
      {Source.root(@agent),
       %Event.MessageQueued{message: Message.new("Ship it.", "m-1", sender: by)}},
      {Source.root(@agent),
       %Event.AgentStarted{node: :wardrik_b@localhost, status: :parked, generation: "9f2c1e7a"}},
      {Source.root(@agent), %Event.AgentStopped{node: :wardrik_b@localhost, reason: :idle}},
      {turn,
       %Event.ContextCompacted{
         stats: %{
           messages_before: 40,
           messages_after: 8,
           tokens_before: 60_000,
           tokens_after: 9_000
         }
       }},
      {Source.root(@agent), %Event.ContextCleared{dropped: 12}},
      {Source.root(@agent), %Event.TriggerFired{name: "sweep", outcome: :asked}},
      {step, %Event.SpanStarted{name: "research"}},
      {step, %Event.SpanFinished{outcome: {:error, :timeout}, duration_ms: 1_200}},
      {step, %Event.DelegationStarted{prompt: "Look into the failing build."}},
      {step,
       %Event.DelegationFinished{outcome: {:ok, "It was a flaky test."}, duration_ms: 9_000}},
      {turn,
       %Event.ModelStarted{
         message_id: "#{turn.trace.span_id}.m0",
         model_spec: "anthropic:claude-sonnet-5",
         decided_by: %{by: :default, hooks: []}
       }},
      {turn,
       %Event.ModelFinished{
         message_id: "#{turn.trace.span_id}.m0",
         outcome: :ok,
         duration_ms: 1_500,
         response: response(asking),
         cost: nil
       }},
      {turn,
       %Event.ModelRetrying{
         message_id: "#{turn.trace.span_id}.m0",
         attempt: 1,
         attempts: 6,
         wait_ms: 800,
         reason: :timeout
       }},
      {turn, %Event.Result{text: "Shipped"}},
      {turn, %Event.Thinking{text: "The build is green."}},
      {turn, %Event.Meta{chunk: %{usage: %{input_tokens: 1}}}},
      {turn, %Event.Chunk{chunk: :anything}},
      {turn, %Event.ToolCall{call: %{name: "deploy"}}},
      {turn, %Event.DeadlineReached{message_count: 6}},
      {tool,
       %Event.ToolStarted{
         call_id: "call_1",
         name: "deploy",
         arguments: %{"repo" => "wardrik"},
         idempotency_key: "acme/@ops/triage/t/call_1",
         decided_by: %{by: :hook, hooks: ["careful"]}
       }},
      {tool,
       %Event.ToolFinished{
         call_id: "call_1",
         name: "deploy",
         result: {:ok, %{"ok" => true, "result" => %{"url" => "https://example.com/1"}}},
         served_by: %{id: "w1", name: "deploys"},
         cost: nil
       }},
      {tool,
       %Event.ToolReplayed{
         call_id: "call_1",
         name: "deploy",
         result: {:ok, %{"ok" => true, "result" => "done"}}
       }},
      {tool,
       %Event.ToolDenied{
         call_id: "call_1",
         name: "deploy",
         reason: "Not today.",
         decided_by: %{by: :person, hooks: ["careful"]}
       }},
      {tool,
       %Event.ToolParked{call_id: "call_1", name: "deploy", prompt: "This ships to production."}},
      {tool, %Event.ToolProgress{call_id: "call_1", name: "deploy", progress: 3, total: 10}}
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
      {:agent_forgotten, id, prefix},
      {:agent_moved, id, :wardrik_b@localhost},
      {:agent_cancelled, id},
      {:agent_cancelled, id, prefix},
      {:agent_cleared, id},
      {:call_killed, id, "call_1"},
      {:trigger_set, id, "sweep"},
      {:trigger_removed, id, "sweep"},
      {:agents_reloaded, [:wardrik_a@localhost, :wardrik_b@localhost]},
      {:room_bound, "slack", "C0123", id, :mentions},
      {:room_unbound, "slack", "C0123"},
      {:token_created, "tok_1", "ci", grant, Principal.new(:user, "jon")},
      {:token_revoked, "tok_1"},
      {:secret_stored, "GITHUB_TOKEN", Prefix.all()},
      {:secret_removed, "GITHUB_TOKEN", Prefix.new!(org: "acme", user: "jon")},
      {:server_added, Key.new(prefix, "crm"), "https://mcp.crm.example/mcp"},
      {:server_removed, Key.new(prefix, "crm")}
    ]
  end

  # The first element of every tuple a union type of `module` lists.
  defp tags(module, name) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    {:type, {^name, {:type, _, :union, members}, []}} =
      Enum.find(types, &match?({:type, {^name, _, _}}, &1))

    for {:type, _, :tuple, [{:atom, _, tag} | _]} <- members, do: tag
  end

  defp kinds(module, name) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    {:type, {^name, {:type, _, :union, members}, []}} =
      Enum.find(types, &match?({:type, {^name, _, _}}, &1))

    for {:remote_type, _, [{:atom, _, kind}, {:atom, _, :t}, []]} <- members, do: kind
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
      assert Enum.sort(kinds(Event, :payload)) ==
               fixtures() |> Enum.map(&elem(&1, 1).__struct__) |> Enum.uniq() |> Enum.sort()
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
        Event.new(source, %Event.ToolDenied{
          call_id: "call_1",
          name: "deploy",
          reason: "No.",
          decided_by: %{by: :default, hooks: []}
        })

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
      assert {:ok, event} = encode(turn(), %Event.TurnResumed{decisions: %{}}, [])

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
      for payload <- [
            %Event.Chunk{chunk: 1},
            %Event.Meta{chunk: %{}},
            %Event.ToolCall{call: %{}},
            %Event.ToolParked{call_id: "c", name: "n", prompt: "p"}
          ],
          do: assert(:skip = encode(turn(), payload))
    end
  end

  describe "tool calls" do
    defp completed(result),
      do:
        elem(
          encode(turn(), %Event.ToolFinished{
            call_id: "call_1",
            name: "deploy",
            result: result,
            served_by: nil,
            cost: nil
          }),
          1
        )["data"]

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
          %Event.ToolStarted{
            call_id: "call_1",
            name: "deploy",
            arguments: %{repo: :wardrik},
            idempotency_key: "key-1",
            decided_by: %{by: :default, hooks: []}
          }
        )

      assert data["tool"]["call"] == %{
               "id" => "call_1",
               "arguments" => %{"repo" => "wardrik"},
               "idempotency_key" => "key-1"
             }
    end

    test "name who decided them, and what answered them" do
      {:ok, %{"data" => started}} =
        encode(turn(), %Event.ToolStarted{
          call_id: "call_1",
          name: "deploy",
          arguments: %{},
          idempotency_key: "k",
          decided_by: %{by: :default, hooks: []}
        })

      assert started["decided"] == %{"by" => "default"}

      {:ok, %{"data" => denied}} =
        encode(
          turn(),
          %Event.ToolDenied{
            call_id: "call_1",
            name: "deploy",
            reason: "No.",
            decided_by: %{by: :hook, hooks: ["careful"]}
          }
        )

      assert denied["decided"] == %{"by" => "hook", "hooks" => ["careful"]}

      {:ok, %{"data" => finished}} =
        encode(
          turn(),
          %Event.ToolFinished{
            call_id: "call_1",
            name: "deploy",
            result: {:ok, 1},
            served_by: %{id: "w1", name: "deploys"},
            cost: nil
          }
        )

      assert finished["served_by"] == %{"id" => "w1", "name" => "deploys"}

      {:ok, %{"data" => unserved}} =
        encode(turn(), %Event.ToolFinished{
          call_id: "call_1",
          name: "deploy",
          result: {:ok, 1},
          served_by: nil,
          cost: nil
        })

      refute Map.has_key?(unserved, "served_by")
    end

    test "carry what a call cost where its tool said, and nothing otherwise" do
      {:ok, %{"data" => priced} = event} =
        encode(
          turn(),
          %Event.ToolFinished{
            call_id: "call_1",
            name: "search",
            result: {:ok, 1},
            served_by: nil,
            cost: %{micro_usd: 4_000, source: :tool}
          }
        )

      valid!(event)
      assert priced["cost"] == %{"micro_usd" => 4_000, "source" => "tool"}
      refute Map.has_key?(completed({:ok, 1}), "cost")
    end

    test "answered from the ledger say they were replayed" do
      {:ok, %{"data" => data}} =
        encode(
          turn(),
          %Event.ToolReplayed{
            call_id: "call_1",
            name: "deploy",
            result: {:ok, %{"ok" => true, "result" => 1}}
          }
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
        encode(turn(), %Event.ModelFinished{
          message_id: "s.m0",
          outcome: :ok,
          duration_ms: 900,
          response: response(message),
          cost: nil
        })

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
          %Event.ModelFinished{
            message_id: "s.m0",
            outcome: :ok,
            duration_ms: 900,
            response: response(message),
            cost: %{micro_usd: 4_200, source: :catalog}
          }
        )

      valid!(event)
      assert priced["cost"] == %{"micro_usd" => 4_200, "source" => "catalog"}

      {:ok, %{"data" => unpriced} = event} =
        encode(turn(), %Event.ModelFinished{
          message_id: "s.m0",
          outcome: :ok,
          duration_ms: 900,
          response: response(message),
          cost: nil
        })

      valid!(event)

      assert Map.fetch(unpriced, "cost") == {:ok, nil}
    end

    test "that were stopped say so, and name their message alone" do
      {:ok, %{"data" => data}} =
        encode(turn(), %Event.ModelFinished{
          message_id: "s.m0",
          outcome: {:error, :interrupted},
          duration_ms: 10,
          response: nil,
          cost: nil
        })

      assert data == %{
               "message" => %{"id" => "s.m0"},
               "status" => "cancelled",
               "duration_ms" => 10
             }
    end

    test "that failed say which try comes next, of how many, after how long, and why" do
      {:ok, event} =
        encode(turn(), %Event.ModelRetrying{
          message_id: "s.m0.2",
          attempt: 2,
          attempts: 6,
          wait_ms: 1_400,
          reason: :timeout
        })

      assert event["type"] == "wardrik.message.retrying"
      assert event["subject"] == "messages/s.m0.2"

      assert event["data"] == %{
               "message" => %{"id" => "s.m0.2"},
               "attempt" => 2,
               "attempts" => 6,
               "wait_ms" => 1_400,
               "error" => %{"type" => "timeout", "message" => "timeout"}
             }
    end

    test "start with the provider and model asked" do
      {:ok, %{"data" => data}} =
        encode(
          turn(),
          %Event.ModelStarted{
            message_id: "s.m0",
            model_spec: {:anthropic, model: "claude-sonnet-5"},
            decided_by: %{by: :default, hooks: []}
          }
        )

      assert data["provider"] == %{"name" => "anthropic"}
      assert data["request"] == %{"model" => "claude-sonnet-5"}
    end

    test "stream as deltas under the message they belong to" do
      {:ok, event} = encode(turn(), %Event.Result{text: "Ship"}, message_id: "s.m0")

      assert event["type"] == "wardrik.message.delta"
      assert event["data"] == %{"message" => %{"id" => "s.m0"}, "delta" => "Ship"}
    end

    test "answered by a tool name the call they answer" do
      {:ok, %{"data" => %{"messages" => [message]}}} =
        encode(turn(), %Event.TurnFinished{
          messages: [Context.tool_result("call_1", "deploy", "done")]
        })

      assert message["parts"] == [
               %{"type" => "tool_call_response", "id" => "call_1", "response" => "done"}
             ]
    end
  end

  describe "interrupts" do
    test "say whether a tool or the model call is waiting, on what, and which tool" do
      model = %{id: "model_1", name: "model", arguments: %{}}
      doubt = Map.put(call("call_2", "refund"), :in_doubt, true)

      {:ok, %{"data" => data}} =
        encode(
          turn(),
          %Event.TurnParked{
            calls: [
              {call("call_1", "deploy"), "Ship?"},
              {model, "Over budget."},
              {doubt, "Again?"}
            ]
          }
        )

      assert data["interrupts"] == [
               %{
                 "id" => "call_1",
                 "reason" => "tool_approval",
                 "message" => "Ship?",
                 "tool_call_id" => "call_1",
                 "name" => "deploy"
               },
               %{"id" => "model_1", "reason" => "model_approval", "message" => "Over budget."},
               %{
                 "id" => "call_2",
                 "reason" => "in_doubt",
                 "message" => "Again?",
                 "tool_call_id" => "call_2",
                 "name" => "refund"
               }
             ]
    end

    test "say what the run had read, which may be what asked for them" do
      labelled = Map.put(call("call_1", "deploy"), :labels, ["outside"])

      {:ok, %{"data" => data}} = encode(turn(), %Event.TurnParked{calls: [{labelled, "Ship?"}]})

      assert [%{"labels" => ["outside"]}] = data["interrupts"]
    end

    test "are resolved by someone, approving or rejecting" do
      {:ok, %{"data" => approved}} =
        encode(turn(), %Event.CallDecided{call_id: "call_1", decision: :approve, by: nil})

      assert approved == %{"interrupt" => %{"id" => "call_1"}, "decision" => "approved"}

      by = Principal.new(:shell, "wardrik")

      {:ok, %{"data" => rejected}} =
        encode(turn(), %Event.CallDecided{call_id: "call_1", decision: {:deny, "No."}, by: by})

      assert rejected["decision"] == "rejected"
      assert rejected["reason"] == "No."
      assert rejected["resolved_by"] == %{"type" => "shell", "id" => "wardrik"}

      {:ok, %{"data" => noted}} =
        encode(turn(), %Event.CallDecided{
          call_id: "call_1",
          decision: {:approve, " Only once. "},
          by: by
        })

      assert noted["decision"] == "approved"
      assert noted["note"] == "Only once."
      refute Map.has_key?(noted, "reason")

      {:ok, %{"data" => blank}} =
        encode(turn(), %Event.CallDecided{call_id: "call_1", decision: {:approve, " "}, by: nil})

      assert blank == %{"interrupt" => %{"id" => "call_1"}, "decision" => "approved"}
    end
  end

  test "a message created names who sent it, where anyone is named" do
    by = Principal.new(:channel, "slack/U1", name: "jon")

    assert {:ok,
            %{
              "data" => %{"sender" => %{"type" => "channel", "id" => "slack/U1", "name" => "jon"}}
            }} =
             encode(Source.root(@agent), %Event.MessageQueued{
               message: Message.new("Hi.", "m-1", sender: by)
             })

    assert {:ok, %{"data" => data}} =
             encode(Source.root(@agent), %Event.MessageQueued{message: Message.new("Hi.", "m-1")})

    refute Map.has_key?(data, "sender")
  end

  test "a run names the messages it answers" do
    {:ok, event} =
      encode(turn(), %Event.TurnStarted{
        messages: [Message.new("one", "m-1"), Message.new("two", "m-2")]
      })

    assert event["data"]["run"]["message_ids"] == ["m-1", "m-2"]
    assert event["subject"] == "runs/" <> event["data"]["run"]["id"]
  end

  describe "steps and subagents" do
    test "a subagent that failed says why" do
      {:ok, event} =
        encode(within(turn(), "research"), %Event.DelegationFinished{
          outcome: {:error, :timeout},
          duration_ms: 5
        })

      assert event["type"] == "wardrik.subagent.failed"
      assert event["data"]["error"]["type"] == "timeout"
      assert event["data"]["agent"] == %{"name" => "research"}
    end

    test "a step that finished says so" do
      {:ok, event} =
        encode(within(turn(), "plan"), %Event.SpanFinished{outcome: :ok, duration_ms: 5})

      assert event["data"] == %{"status" => "ok", "duration_ms" => 5}
    end

    test "a step a stopped turn interrupted is cancelled" do
      {:ok, event} =
        encode(within(turn(), "plan"), %Event.SpanFinished{
          outcome: {:error, :interrupted},
          duration_ms: 5
        })

      assert event["data"] == %{"status" => "cancelled", "duration_ms" => 5}
      assert {:ok, _} = JSV.validate(event["data"], build("step.completed"))
    end
  end

  test "a model is read from however it was named" do
    started = fn spec ->
      {:ok, %{"data" => data}} =
        encode(turn(), %Event.ModelStarted{
          message_id: "s.m0",
          model_spec: spec,
          decided_by: %{by: :default, hooks: []}
        })

      {data["provider"], data["request"]["model"]}
    end

    assert started.("claude-sonnet-5") == {nil, "claude-sonnet-5"}
    assert started.(%{provider: :openai, id: "gpt-5"}) == {%{"name" => "openai"}, "gpt-5"}
    assert started.(:odd) == {nil, ":odd"}
  end
end
