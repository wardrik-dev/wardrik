defmodule Wardrik.Event.CodecTest do
  use ExUnit.Case, async: true

  alias Wardrik.Agent.Activity
  alias Wardrik.Agent.Message
  alias Wardrik.Audit
  alias Wardrik.Bus
  alias Wardrik.Bus.Source
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Event.Codec
  alias Wardrik.Principal
  alias Wardrik.Resource

  @schemas WardrikProtocol.dir()
  @agent Wardrik.AgentID.parse!("acme/@ops/triage")

  defp read(name), do: @schemas |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()

  defp build(name), do: JSV.build!(read(name), resolver: WardrikProtocol.Resolver)

  defp turn, do: Source.root(@agent, name: "turn")
  defp within(source, name), do: Source.child(source, name: name)

  defp call(id, name), do: %{id: id, name: name, arguments: %{"repo" => "wardrik"}}

  defp started(id, name),
    do: %Bus.ToolStarted{
      call_id: id,
      name: name,
      arguments: %{"repo" => "wardrik"},
      idempotency_key: "acme/@ops/triage/t/" <> id,
      decided_by: %{by: :default, hooks: []}
    }

  defp answer(message, usage \\ %{input_tokens: 12, output_tokens: 4, cached_tokens: 3}) do
    %Wardrik.LLM.Answer{
      id: "resp_1",
      model: "claude-sonnet-5",
      message: message,
      usage: struct!(Wardrik.LLM.Usage, usage),
      finish_reason: :stop
    }
  end

  defp deploying,
    do: %Assistant{
      parts: [%ToolCall{id: "call_1", name: "deploy", arguments: %{"repo" => "wardrik"}}]
    }

  # One payload of every shape `Wardrik.Bus.Event.payload/0` lists, with the source
  # each is emitted on.
  defp fixtures do
    turn = turn()
    tool = within(turn, "deploy")
    step = within(turn, "research")
    by = Principal.new("slack:U1", name: "jon")

    asking = deploying()

    [
      {turn, %Bus.TurnStarted{messages: [Message.new("Ship it.", "m-1")]}},
      {turn,
       %Bus.TurnFinished{
         messages: [
           asking,
           %ToolResult{call_id: "call_1", name: "deploy", parts: [%Text{text: "done"}]},
           Assistant.new("Shipped.")
         ]
       }},
      {turn, %Bus.TurnFailed{reason: :timeout}},
      {turn,
       %Bus.TurnInterrupted{
         stats: %{dropped: 1, kept: 0, resolution: :killed, elapsed_ms: 2_000}
       }},
      {turn,
       %Bus.TurnParked{
         calls: [
           {call("call_1", "deploy"), "This ships to production."},
           {call("call_2", "refund") |> Map.put(:in_doubt, true) |> Map.put(:labels, ["outside"]),
            "refund may already have run."}
         ]
       }},
      {turn, %Bus.TurnResumed{decisions: %{"call_1" => :approve}}},
      {turn, %Bus.CallDecided{call_id: "call_1", decision: {:deny, "Not today."}, by: by}},
      {Source.root(@agent),
       %Bus.MessageQueued{message: Message.new("Ship it.", "m-1", sender: by)}},
      {Source.root(@agent),
       %Bus.AgentStarted{node: :wardrik_b@localhost, status: :parked, generation: "9f2c1e7a"}},
      {Source.root(@agent), %Bus.AgentStopped{node: :wardrik_b@localhost, reason: :idle}},
      {turn,
       %Bus.ContextCompacted{
         stats: %{
           messages_before: 40,
           messages_after: 8,
           tokens_before: 60_000,
           tokens_after: 9_000
         }
       }},
      {Source.root(@agent), %Bus.ContextCleared{dropped: 12}},
      {Source.root(@agent), %Bus.TriggerFired{name: "sweep", outcome: :asked}},
      {tool,
       %Bus.ActivityChanged{
         activity: %Activity{doing: [started("call_1", "deploy")], since: 1_000_000, pending: 1}
       }},
      {step, %Bus.SpanStarted{name: "research"}},
      {step, %Bus.SpanFinished{outcome: {:error, :timeout}, duration_ms: 1_200}},
      {step, %Bus.DelegationStarted{prompt: "Look into the failing build."}},
      {step, %Bus.DelegationFinished{outcome: {:ok, "It was a flaky test."}, duration_ms: 9_000}},
      {turn,
       %Bus.ModelStarted{
         message_id: "#{turn.trace.span_id}.m0",
         model_spec: "anthropic:claude-sonnet-5",
         decided_by: %{by: :default, hooks: []}
       }},
      {turn,
       %Bus.ModelFinished{
         message_id: "#{turn.trace.span_id}.m0",
         outcome: :ok,
         duration_ms: 1_500,
         answer: answer(asking),
         cost: nil
       }},
      {turn,
       %Bus.ModelRetrying{
         message_id: "#{turn.trace.span_id}.m0",
         attempt: 1,
         attempts: 6,
         wait_ms: 800,
         reason: :timeout
       }},
      {turn, %Bus.Result{text: "Shipped"}},
      {turn, %Bus.Thinking{text: "The build is green."}},
      {turn, %Bus.ToolCall{call: %ToolCall{id: "call_1", name: "deploy", arguments: %{}}}},
      {turn, %Bus.DeadlineReached{message_count: 6}},
      {tool,
       %Bus.ToolStarted{
         call_id: "call_1",
         name: "deploy",
         arguments: %{"repo" => "wardrik"},
         idempotency_key: "acme/@ops/triage/t/call_1",
         decided_by: %{by: :hook, hooks: ["careful"]}
       }},
      {tool,
       %Bus.ToolFinished{
         call_id: "call_1",
         name: "deploy",
         result: {:ok, %{"ok" => true, "result" => %{"url" => "https://example.com/1"}}},
         served_by: %{id: "w1", name: "deploys"},
         cost: nil
       }},
      {tool,
       %Bus.ToolReplayed{
         call_id: "call_1",
         name: "deploy",
         result: {:ok, %{"ok" => true, "result" => "done"}}
       }},
      {tool,
       %Bus.ToolDenied{
         call_id: "call_1",
         name: "deploy",
         reason: "Not today.",
         decided_by: %{by: :person, hooks: ["careful"]}
       }},
      {tool,
       %Bus.ToolParked{call_id: "call_1", name: "deploy", prompt: "This ships to production."}},
      {tool, %Bus.ToolProgress{call_id: "call_1", name: "deploy", progress: 3, total: 10}}
    ]
  end

  # One change of every shape `Audit.action/0` lists.
  defp changes do
    id = @agent
    pattern = Resource.parse!("acme/agent/*")

    token = %Wardrik.Token{
      principal: Principal.new("acme/@jon"),
      scope: [Wardrik.Role.bind([:reader, :definer], [pattern])],
      policy: "careful",
      expires: ~U[2026-12-01 00:00:00Z]
    }

    [
      {:agent_defined, id},
      {:agent_spawned, id, :wardrik_b@localhost},
      {:agent_stopped, id},
      {:agent_forgotten, id},
      {:agent_forgotten, id, pattern},
      {:agent_moved, id, :wardrik_b@localhost},
      {:agent_cancelled, id},
      {:agent_cancelled, id, pattern},
      {:agent_cleared, id},
      {:call_killed, id, "call_1"},
      {:trigger_set, id, "sweep"},
      {:trigger_removed, id, "sweep"},
      {:agents_reloaded, [:wardrik_a@localhost, :wardrik_b@localhost]},
      {:room_bound, "slack", "C0123", id, :mentions},
      {:room_unbound, "slack", "C0123"},
      {:token_created, "tok_1", "ci", token},
      {:token_revoked, "tok_1"},
      {:secret_stored, "GITHUB_TOKEN", Resource.deployment()},
      {:secret_removed, "GITHUB_TOKEN", Resource.parse!("acme/@jon")},
      {:server_added, Resource.parse!("acme/server/crm"), "https://mcp.crm.example/mcp"},
      {:server_removed, Resource.parse!("acme/server/crm")}
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
    do: Codec.encode(Bus.Event.new(source, payload), opts)

  describe "every payload" do
    test "has a fixture here" do
      assert Enum.sort(kinds(Bus.Event, :payload)) ==
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
      by = Principal.new("shell:jon")

      for action <- changes(), anyone <- [by, nil] do
        assert {:ok, event} = Codec.encode(Audit.new(action, anyone), sequence: 7)
        valid!(event)
      end
    end

    test "comes from the audit, at the root of a trace of its own, and names who made it" do
      by = Principal.new("acme/@jon", name: "Jon")
      audit = Audit.new({:agent_forgotten, @agent}, by)

      assert {:ok, event} = Codec.encode(audit, sequence: 7)

      assert %{
               "id" => id,
               "source" => "wardrik://local/audit",
               "type" => "wardrik.agent.forgotten",
               "subject" => "acme/@ops/agent/triage",
               "sequence" => "000000000007",
               "data" =>
                 %{
                   "agent" => %{"id" => "acme/@ops/triage"},
                   "actor" => %{"id" => "acme/@jon", "name" => "Jon"}
                 } = data
             } = event

      refute Map.has_key?(data, "assumed_by")
      assert id == audit.id
      assert event["traceparent"] == "00-#{audit.trace.trace_id}-#{audit.trace.span_id}-01"
      refute Map.has_key?(event, "parentspanid")
    end

    test "names who acted for the actor, first to last" do
      front = Principal.new("acme/agent/front")

      audit = %{
        Audit.new({:agent_cleared, @agent}, Principal.new("acme/@jon"))
        | assumed_by: [front]
      }

      assert {:ok, %{"data" => %{"assumed_by" => [%{"id" => "acme/agent/front"}]}} = event} =
               Codec.encode(audit, sequence: 7)

      valid!(event)
    end

    test "says what a token allows, and never its secret" do
      {:token_created, _id, _name, token} = List.keyfind(changes(), :token_created, 0)

      assert {:ok, %{"data" => data}} =
               Codec.encode(Audit.new({:token_created, "tok_1", "ci", token}, nil))

      assert data == %{
               "token" => %{"id" => "tok_1", "name" => "ci"},
               "principal" => %{"id" => "acme/@jon"},
               "statements" => [
                 %{
                   "actions" =>
                     Enum.uniq(Wardrik.Role.actions(:reader) ++ Wardrik.Role.actions(:definer)),
                   "resources" => ["acme/agent/*"]
                 }
               ],
               "policy" => "careful",
               "expires" => "2026-12-01T00:00:00Z"
             }
    end

    test "says nothing of an actor none is known for, or the owner of a deployment's secret" do
      assert {:ok, %{"data" => data}} =
               Codec.encode(Audit.new({:secret_stored, "KEY", Resource.deployment()}, nil))

      assert data == %{"secret" => %{"name" => "KEY"}}

      jon = Resource.parse!("acme/@jon")

      assert {:ok, %{"data" => %{"owner" => "acme/@jon"}}} =
               Codec.encode(Audit.new({:secret_removed, "KEY", jon}, nil))
    end
  end

  describe "the envelope" do
    test "carries the event's id, its agent, its time and its span" do
      source = within(turn(), "deploy")

      event =
        Bus.Event.new(source, %Bus.ToolDenied{
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
      assert {:ok, event} = encode(turn(), %Bus.TurnResumed{decisions: %{}}, [])

      refute Map.has_key?(event, "sequence")
      refute Map.has_key?(event, "parentspanid")
    end

    test "names the log it came from" do
      assert Codec.source(@agent) == "wardrik://local/agents/acme/@ops/triage"
      assert Codec.source(:audit) == "wardrik://local/audit"
    end
  end

  describe "events dropped" do
    test "say where a reader was and where the log now starts, under the agent's log" do
      event = Codec.dropped(@agent, after: 12, oldest: 30)
      valid!(event)

      assert %{
               "type" => "wardrik.events.dropped",
               "source" => "wardrik://local/agents/acme/@ops/triage",
               "subject" => "agents/acme/@ops/triage",
               "data" => %{"after" => 12, "oldest" => 30}
             } = event

      refute Map.has_key?(event, "sequence")
    end
  end

  describe "durable and live" do
    test "deltas, progress and what an agent is doing are live, everything sent otherwise durable" do
      refute Codec.durable?(:result)
      refute Codec.durable?(:thinking)
      refute Codec.durable?(:tool_progress)
      refute Codec.durable?(:activity_changed)
      assert Codec.durable?(:tool_started)
      assert Codec.durable?(:turn_parked)
    end

    test "a tool call as it streams and the per-call park are not sent" do
      for payload <- [
            %Bus.ToolCall{call: %ToolCall{id: "c", name: "n", arguments: %{}}},
            %Bus.ToolParked{call_id: "c", name: "n", prompt: "p"}
          ],
          do: assert(:skip = encode(turn(), payload))
    end
  end

  describe "tool calls" do
    defp completed(result),
      do:
        elem(
          encode(turn(), %Bus.ToolFinished{
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
          %Bus.ToolStarted{
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
        encode(turn(), %Bus.ToolStarted{
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
          %Bus.ToolDenied{
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
          %Bus.ToolFinished{
            call_id: "call_1",
            name: "deploy",
            result: {:ok, 1},
            served_by: %{id: "w1", name: "deploys"},
            cost: nil
          }
        )

      assert finished["served_by"] == %{"id" => "w1", "name" => "deploys"}

      {:ok, %{"data" => unserved}} =
        encode(turn(), %Bus.ToolFinished{
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
          %Bus.ToolFinished{
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
          %Bus.ToolReplayed{
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
      message = deploying()

      {:ok, %{"data" => data}} =
        encode(turn(), %Bus.ModelFinished{
          message_id: "s.m0",
          outcome: :ok,
          duration_ms: 900,
          answer: answer(message),
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
      message = Assistant.new("hi")

      {:ok, %{"data" => priced} = event} =
        encode(
          turn(),
          %Bus.ModelFinished{
            message_id: "s.m0",
            outcome: :ok,
            duration_ms: 900,
            answer: answer(message),
            cost: %{micro_usd: 4_200, source: :catalog}
          }
        )

      valid!(event)
      assert priced["cost"] == %{"micro_usd" => 4_200, "source" => "catalog"}

      {:ok, %{"data" => unpriced} = event} =
        encode(turn(), %Bus.ModelFinished{
          message_id: "s.m0",
          outcome: :ok,
          duration_ms: 900,
          answer: answer(message),
          cost: nil
        })

      valid!(event)

      assert Map.fetch(unpriced, "cost") == {:ok, nil}
    end

    test "that were stopped say so, and name their message alone" do
      {:ok, %{"data" => data}} =
        encode(turn(), %Bus.ModelFinished{
          message_id: "s.m0",
          outcome: {:error, :interrupted},
          duration_ms: 10,
          answer: nil,
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
        encode(turn(), %Bus.ModelRetrying{
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
          %Bus.ModelStarted{
            message_id: "s.m0",
            model_spec: {:anthropic, model: "claude-sonnet-5"},
            decided_by: %{by: :default, hooks: []}
          }
        )

      assert data["provider"] == %{"name" => "anthropic"}
      assert data["request"] == %{"model" => "claude-sonnet-5"}
    end

    test "stream as deltas under the message they belong to" do
      {:ok, event} = encode(turn(), %Bus.Result{text: "Ship"}, message_id: "s.m0")

      assert event["type"] == "wardrik.message.delta"
      assert event["data"] == %{"message" => %{"id" => "s.m0"}, "delta" => "Ship"}
    end

    test "answered by a tool name the call they answer" do
      {:ok, %{"data" => %{"messages" => [message]}}} =
        encode(turn(), %Bus.TurnFinished{
          messages: [%ToolResult{call_id: "call_1", name: "deploy", parts: [%Text{text: "done"}]}]
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
          %Bus.TurnParked{
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

      {:ok, %{"data" => data}} = encode(turn(), %Bus.TurnParked{calls: [{labelled, "Ship?"}]})

      assert [%{"labels" => ["outside"]}] = data["interrupts"]
    end

    test "are resolved by someone, approving or rejecting" do
      {:ok, %{"data" => approved}} =
        encode(turn(), %Bus.CallDecided{call_id: "call_1", decision: :approve, by: nil})

      assert approved == %{"interrupt" => %{"id" => "call_1"}, "decision" => "approved"}

      by = Principal.new("shell:wardrik")

      {:ok, %{"data" => rejected}} =
        encode(turn(), %Bus.CallDecided{call_id: "call_1", decision: {:deny, "No."}, by: by})

      assert rejected["decision"] == "rejected"
      assert rejected["reason"] == "No."
      assert rejected["resolved_by"] == %{"id" => "shell:wardrik"}

      {:ok, %{"data" => noted}} =
        encode(turn(), %Bus.CallDecided{
          call_id: "call_1",
          decision: {:approve, " Only once. "},
          by: by
        })

      assert noted["decision"] == "approved"
      assert noted["note"] == "Only once."
      refute Map.has_key?(noted, "reason")

      {:ok, %{"data" => blank}} =
        encode(turn(), %Bus.CallDecided{call_id: "call_1", decision: {:approve, " "}, by: nil})

      assert blank == %{"interrupt" => %{"id" => "call_1"}, "decision" => "approved"}
    end
  end

  describe "what an agent is doing" do
    defp changed(doing) do
      activity = %Activity{doing: doing, since: 1_760_788_800_000_000, pending: 0}
      {:ok, event} = encode(turn(), %Bus.ActivityChanged{activity: activity}, [])
      valid!(event)
      event
    end

    test "is every call running, each as the type of the event that set it and the call it names" do
      event = changed([started("call_1", "web_search"), started("call_2", "fetch_page")])

      assert event["subject"] == "agents/acme/@ops/triage"

      assert event["data"]["activity"] == %{
               "doing" => [
                 %{
                   "type" => "wardrik.tool_call.started",
                   "tool" => %{"name" => "web_search", "call" => %{"id" => "call_1"}}
                 },
                 %{
                   "type" => "wardrik.tool_call.started",
                   "tool" => %{"name" => "fetch_page", "call" => %{"id" => "call_2"}}
                 }
               ],
               "since" => "2025-10-18T12:00:00.000000Z",
               "pending" => 0
             }
    end

    test "is nothing when idle, and otherwise one thing, which says what it needs to" do
      parked = %Bus.TurnParked{calls: [{call("call_1", "deploy"), "Ship it?"}]}

      retrying = %Bus.ModelRetrying{
        message_id: "s.m0",
        attempt: 2,
        attempts: 6,
        wait_ms: 900,
        reason: :timeout
      }

      for {doing, said} <- [
            {:idle, []},
            {%Bus.TurnStarted{messages: []}, [%{"type" => "wardrik.run.started"}]},
            {%Bus.TurnResumed{decisions: %{}}, [%{"type" => "wardrik.run.resumed"}]},
            {parked,
             [
               %{
                 "type" => "wardrik.run.interrupted",
                 "interrupts" => [
                   %{
                     "id" => "call_1",
                     "reason" => "tool_approval",
                     "message" => "Ship it?",
                     "tool_call_id" => "call_1",
                     "name" => "deploy"
                   }
                 ]
               }
             ]},
            {%Bus.ModelStarted{message_id: "s.m0", model_spec: "x:y", decided_by: nil},
             [%{"type" => "wardrik.message.started", "message" => %{"id" => "s.m0"}}]},
            {retrying,
             [
               %{
                 "type" => "wardrik.message.retrying",
                 "message" => %{"id" => "s.m0"},
                 "attempt" => 2,
                 "attempts" => 6,
                 "wait_ms" => 900
               }
             ]},
            {%Bus.SpanStarted{name: "compacting history"},
             [%{"type" => "wardrik.step.started", "step" => %{"name" => "compacting history"}}]},
            {%Bus.ToolDenied{call_id: "c", name: "rm", reason: "No.", decided_by: nil},
             [
               %{
                 "type" => "wardrik.tool_call.denied",
                 "tool" => %{"name" => "rm", "call" => %{"id" => "c"}}
               }
             ]},
            {%Bus.ToolReplayed{call_id: "c", name: "rm", result: {:ok, "done"}},
             [
               %{
                 "type" => "wardrik.tool_call.completed",
                 "tool" => %{"name" => "rm", "call" => %{"id" => "c"}}
               }
             ]}
          ] do
        assert changed(doing)["data"]["activity"]["doing"] == said
      end
    end
  end

  test "a message created names who sent it, where anyone is named" do
    by = Principal.new("slack:U1", name: "jon")

    assert {:ok,
            %{
              "data" => %{"sender" => %{"id" => "slack:U1", "name" => "jon"}}
            }} =
             encode(Source.root(@agent), %Bus.MessageQueued{
               message: Message.new("Hi.", "m-1", sender: by)
             })

    assert {:ok, %{"data" => data}} =
             encode(Source.root(@agent), %Bus.MessageQueued{message: Message.new("Hi.", "m-1")})

    refute Map.has_key?(data, "sender")
  end

  test "a run names the messages it answers" do
    {:ok, event} =
      encode(turn(), %Bus.TurnStarted{
        messages: [Message.new("one", "m-1"), Message.new("two", "m-2")]
      })

    assert event["data"]["run"]["message_ids"] == ["m-1", "m-2"]
    assert event["subject"] == "runs/" <> event["data"]["run"]["id"]
  end

  describe "steps and subagents" do
    test "a subagent that failed says why" do
      {:ok, event} =
        encode(within(turn(), "research"), %Bus.DelegationFinished{
          outcome: {:error, :timeout},
          duration_ms: 5
        })

      assert event["type"] == "wardrik.subagent.failed"
      assert event["data"]["error"]["type"] == "timeout"
      assert event["data"]["agent"] == %{"name" => "research"}
    end

    test "a step that finished says so" do
      {:ok, event} =
        encode(within(turn(), "plan"), %Bus.SpanFinished{outcome: :ok, duration_ms: 5})

      assert event["data"] == %{"status" => "ok", "duration_ms" => 5}
    end

    test "a step a stopped turn interrupted is cancelled" do
      {:ok, event} =
        encode(within(turn(), "plan"), %Bus.SpanFinished{
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
        encode(turn(), %Bus.ModelStarted{
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
