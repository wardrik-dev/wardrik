defmodule Wardrik.Event.Codec do
  @moduledoc """
  A `Wardrik.Event`, or a `Wardrik.Audit` change, as a CloudEvent: the map,
  with string keys, that the event log stores and the HTTP API sends.

      {:ok, cloud_event} = Wardrik.Event.Codec.encode(event, sequence: 41)

  ## The envelope

  CloudEvents 1.0 in structured JSON:

    * `specversion` - `"1.0"`
    * `id` - the event's UUIDv7
    * `source` - the agent, as `wardrik://local/agents/<key>`, or
      `wardrik://local/audit` for a change people made
    * `type` - `wardrik.` then a noun and a past-tense verb, the same string as
      the event's OpenTelemetry event name
    * `subject` - what the event is about: `runs/…`, `messages/…`,
      `tool_calls/…`, `interrupts/…`, `steps/…` or `agents/…`, and for a
      change, `agents/…`, an agent or a prefix, `agents`, every one,
      `rooms/…`, `tokens/…` or `secrets/…`
    * `time` - RFC 3339 in UTC, to the microsecond
    * `datacontenttype` - `"application/json"`
    * `dataschema` - `urn:wardrik:schema:v1:<type>`, the JSON Schema the data
      follows, which `wardrik_protocol` holds
    * `sequence` - CloudEvents' sequence extension: the event's place in its
      log, zero-padded to #{12} digits, for a durable event given one
    * `traceparent` - the Distributed Tracing extension: the event's trace, a
      run, and its span, in W3C Trace Context form
    * `parentspanid` - the span that holds the event's span, where there is one

  ## The data

  A key path in `data` is an OpenTelemetry GenAI attribute name without its
  `gen_ai.` prefix, as nested objects: `tool.call.id` is `gen_ai.tool.call.id`.
  Paths under `error` keep their own name, and paths OpenTelemetry has no name
  for are Wardrik's own. See `Wardrik.Event.Codec.Value` for the values.

  ## Durable and live

  A durable event goes in the log and takes a sequence number. A live one, a
  text or reasoning delta or a tool's progress, is streamed and never kept,
  and a client that reconnects reads the whole text from `message.completed`.
  A delta names its message with the `:message_id` option, since the model
  call it streams from announced it.

  Provider stream records, `:chunk`, `:meta` and `:tool_call`, and the
  per-call `:tool_parked`, which `run.interrupted` lists, are not sent:
  `encode/2` answers `:skip`.

  ## Changes

  A `Wardrik.Audit` change is durable, at the root of a trace of its own,
  and its data says who made it, as `actor`, where that is known.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Audit
  alias Wardrik.Call.Pipeline
  alias Wardrik.Event
  alias Wardrik.Event.Codec.Value

  @padding 12

  @live [:result, :thinking, :tool_progress]
  @skipped [:chunk, :meta, :tool_call, :tool_parked]

  @runs [
    :turn_started,
    :turn_finished,
    :turn_failed,
    :turn_interrupted,
    :turn_parked,
    :turn_resumed,
    :deadline_reached,
    :call_decided
  ]
  @agent [
    :message_queued,
    :agent_started,
    :agent_stopped,
    :context_compacted,
    :context_cleared,
    :trigger_fired
  ]
  @steps [:span_started, :span_finished, :delegation_started, :delegation_finished]
  @messages [:model_started, :model_finished, :result, :thinking]

  @doc """
  The CloudEvent for `event`, or `:skip` for one that is not sent.

  Options:

    * `:sequence` - the event's place in its log
    * `:message_id` - the message a text or reasoning delta belongs to
  """
  @spec encode(Event.t() | Audit.t(), keyword()) :: {:ok, map()} | :skip
  def encode(event, opts \\ [])

  def encode(%Event{} = event, opts) do
    if Event.type(event) in @skipped do
      :skip
    else
      {type, subject, data} = describe(Event.type(event), event, opts)
      source = source(event.source.agent_id)
      {:ok, envelope(event, source, event.source.trace, {type, subject, data}, opts)}
    end
  end

  def encode(%Audit{} = audit, opts) do
    {type, subject, data} = change(audit.action)
    data = Value.put(data, "actor", Value.principal(audit.by))
    {:ok, envelope(audit, source(:audit), audit.trace, {type, subject, data}, opts)}
  end

  @doc "Whether events of an internal type go in the log, rather than being streamed alone."
  @spec durable?(atom()) :: boolean()
  def durable?(type) when is_atom(type), do: type not in @live and type not in @skipped

  @doc "The CloudEvents `source` of a log's events: an agent's, or `:audit`."
  @spec source(Event.Log.log()) :: String.t()
  def source(:audit), do: "wardrik://local/audit"
  def source(agent_id), do: "wardrik://local/agents/#{agent_id}"

  @doc "The URI of the JSON Schema for a CloudEvent type's data."
  @spec schema(String.t()) :: String.t()
  def schema("wardrik." <> type), do: "urn:wardrik:schema:v1:" <> type

  defp envelope(event, source, trace, {type, subject, data}, opts) do
    %{
      "specversion" => "1.0",
      "id" => event.id,
      "source" => source,
      "type" => "wardrik." <> type,
      "subject" => subject,
      "time" => event.at |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
      "datacontenttype" => "application/json",
      "dataschema" => schema("wardrik." <> type),
      "traceparent" => "00-#{trace.trace_id}-#{trace.span_id}-01",
      "data" => data
    }
    |> Value.put("parentspanid", trace.parent_span_id)
    |> Value.put("sequence", sequence(Keyword.get(opts, :sequence)))
  end

  defp sequence(nil), do: nil

  defp sequence(n) when is_integer(n) and n > 0,
    do: n |> Integer.to_string() |> String.pad_leading(@padding, "0")

  defp describe(type, event, opts) when type in @runs, do: run(event.payload, event, opts)
  defp describe(type, event, opts) when type in @agent, do: agent(event.payload, event, opts)
  defp describe(type, event, opts) when type in @steps, do: step(event.payload, event, opts)
  defp describe(type, event, opts) when type in @messages, do: message(event.payload, event, opts)
  defp describe(_tool, event, opts), do: tool(event.payload, event, opts)

  # -- runs --------------------------------------------------------------------

  defp run(%Event.TurnStarted{messages: messages}, event, _opts),
    do: in_run("run.started", event, %{"message_ids" => Enum.map(messages, & &1.id)}, %{})

  defp run(%Event.TurnFinished{messages: messages}, event, _opts),
    do: in_run("run.completed", event, %{}, %{"messages" => Enum.map(messages, &Value.message/1)})

  defp run(%Event.TurnFailed{reason: reason}, event, _opts),
    do: in_run("run.failed", event, %{}, %{"error" => Value.error(reason)})

  defp run(%Event.TurnInterrupted{stats: stats}, event, _opts) do
    in_run("run.cancelled", event, %{}, %{
      "dropped" => stats.dropped,
      "kept" => stats.kept,
      "resolution" => to_string(stats.resolution),
      "duration_ms" => stats.elapsed_ms
    })
  end

  defp run(%Event.TurnParked{calls: calls}, event, _opts),
    do:
      in_run("run.interrupted", event, %{}, %{
        "interrupts" => Enum.map(calls, &Value.interrupt/1)
      })

  defp run(%Event.TurnResumed{}, event, _opts),
    do: in_run("run.resumed", event, %{}, %{})

  defp run(%Event.DeadlineReached{message_count: count}, event, _opts),
    do: in_run("run.deadline_exceeded", event, %{}, %{"message_count" => count})

  defp run(%Event.CallDecided{call_id: call_id, decision: decision, by: by}, _event, _opts) do
    {verdict, key, said} =
      case decision do
        :approve -> {"approved", "note", nil}
        {:approve, note} -> {"approved", "note", Pipeline.note(note)}
        {:deny, reason} -> {"rejected", "reason", reason}
      end

    data =
      %{"interrupt" => %{"id" => call_id}, "decision" => verdict}
      |> Value.put(key, said)
      |> Value.put("resolved_by", Value.principal(by))

    {"interrupt.resolved", "interrupts/" <> call_id, data}
  end

  # -- the agent and its conversation --------------------------------------------

  defp agent(%Event.MessageQueued{message: message}, _event, _opts) do
    data =
      Value.put(%{"message" => Value.user(message)}, "sender", Value.principal(message.sender))

    {"message.created", "messages/" <> message.id, data}
  end

  defp agent(
         %Event.AgentStarted{node: node, status: status, generation: generation},
         event,
         _opts
       ) do
    id = event.source.agent_id
    key = to_string(id)

    {"agent.started", "agents/" <> key,
     %{
       "agent" => %{"id" => key, "name" => id.name},
       "conversation" => %{"id" => key <> "/" <> generation},
       "node" => to_string(node),
       "status" => to_string(status)
     }}
  end

  defp agent(%Event.AgentStopped{node: node, reason: reason}, event, _opts) do
    key = to_string(event.source.agent_id)

    {"agent.stopped", "agents/" <> key,
     %{"agent" => %{"id" => key}, "node" => to_string(node), "reason" => to_string(reason)}}
  end

  defp agent(%Event.ContextCompacted{stats: stats}, event, _opts) do
    {"conversation.compacted", "agents/#{event.source.agent_id}",
     %{
       "messages_before" => stats.messages_before,
       "messages_after" => stats.messages_after,
       "tokens_before" => stats.tokens_before,
       "tokens_after" => stats.tokens_after
     }}
  end

  defp agent(%Event.ContextCleared{dropped: dropped}, event, _opts),
    do:
      {"conversation.cleared", "agents/#{event.source.agent_id}", %{"messages_before" => dropped}}

  defp agent(%Event.TriggerFired{name: name, outcome: outcome}, event, _opts) do
    {"trigger.fired", "agents/#{event.source.agent_id}",
     %{"trigger" => %{"name" => name}, "status" => to_string(outcome)}}
  end

  # -- steps and subagents -------------------------------------------------------

  defp step(%Event.SpanStarted{name: name}, event, _opts),
    do: {"step.started", step_subject(event), %{"step" => %{"name" => name}}}

  defp step(%Event.SpanFinished{outcome: outcome, duration_ms: ms}, event, _opts),
    do: {"step.completed", step_subject(event), outcome(%{"duration_ms" => ms}, outcome)}

  defp step(%Event.DelegationStarted{prompt: prompt}, event, _opts),
    do: {"subagent.started", step_subject(event), subagent(event, %{"prompt" => prompt})}

  defp step(%Event.DelegationFinished{outcome: {:ok, text}, duration_ms: ms}, event, _opts) do
    data = %{"message" => Value.assistant(text), "duration_ms" => ms}
    {"subagent.completed", step_subject(event), subagent(event, data)}
  end

  defp step(%Event.DelegationFinished{outcome: {:error, reason}, duration_ms: ms}, event, _opts) do
    data = %{"error" => Value.error(reason), "duration_ms" => ms}
    {"subagent.failed", step_subject(event), subagent(event, data)}
  end

  # -- assistant messages --------------------------------------------------------

  defp message(
         %Event.ModelStarted{message_id: message_id, model_spec: spec, decided_by: decided_by},
         _event,
         _opts
       ) do
    {provider, model} = Value.model(spec)

    data =
      %{
        "message" => %{"id" => message_id},
        "request" => %{"model" => model},
        "decided" => Value.decided(decided_by)
      }
      |> Value.put("provider", provider && %{"name" => provider})

    {"message.started", "messages/" <> message_id, data}
  end

  defp message(
         %Event.ModelFinished{
           message_id: message_id,
           outcome: outcome,
           duration_ms: ms,
           response: response,
           cost: cost
         },
         _event,
         _opts
       ) do
    data =
      %{"message" => answered(message_id, response), "duration_ms" => ms}
      |> outcome(outcome)
      |> Value.put("response", response(response))
      |> Value.put("usage", response && Value.usage(response.usage))
      |> priced(response, cost)

    {"message.completed", "messages/" <> message_id, data}
  end

  defp message(%Event.Result{text: text}, _event, opts), do: delta("message.delta", text, opts)

  defp message(%Event.Thinking{text: text}, _event, opts),
    do: delta("reasoning.delta", text, opts)

  # A model that answered and that nobody prices is said to cost null, which
  # is not the same as nothing; one that never answered says nothing of cost.
  defp priced(data, nil, _cost), do: data
  defp priced(data, _response, cost), do: Map.put(data, "cost", Value.cost(cost))

  # -- tool calls ----------------------------------------------------------------

  defp tool(
         %Event.ToolStarted{
           call_id: id,
           name: name,
           arguments: arguments,
           idempotency_key: key,
           decided_by: decided_by
         },
         _event,
         _opts
       ) do
    call =
      %{"id" => id, "idempotency_key" => key}
      |> Value.capped("arguments", Value.json(arguments))

    {"tool_call.started", "tool_calls/" <> id,
     %{"tool" => %{"name" => name, "call" => call}, "decided" => Value.decided(decided_by)}}
  end

  defp tool(
         %Event.ToolFinished{
           call_id: id,
           name: name,
           result: result,
           served_by: served_by,
           cost: cost
         },
         _event,
         _opts
       ),
       do: completed(id, name, result, false, served_by, cost)

  defp tool(%Event.ToolReplayed{call_id: id, name: name, result: result}, _event, _opts),
    do: completed(id, name, result, true, nil, nil)

  defp tool(
         %Event.ToolDenied{call_id: id, name: name, reason: reason, decided_by: decided_by},
         _event,
         _opts
       ) do
    {"tool_call.denied", "tool_calls/" <> id,
     %{
       "tool" => %{"name" => name, "call" => %{"id" => id}},
       "reason" => reason,
       "decided" => Value.decided(decided_by)
     }}
  end

  defp tool(
         %Event.ToolProgress{call_id: id, name: name, progress: progress, total: total},
         _event,
         _opts
       ) do
    data =
      %{"tool" => %{"name" => name, "call" => %{"id" => id}}, "progress" => progress}
      |> Value.put("total", total)

    {"tool_call.progress", "tool_calls/" <> id, data}
  end

  # -- changes people made -------------------------------------------------------

  defp change({:agent_defined, id}), do: agent_change("agent.defined", id, %{})

  defp change({:agent_spawned, id, node}),
    do: agent_change("agent.spawned", id, %{"node" => to_string(node)})

  defp change({:agent_stopped, id}), do: agent_change("agent.stopped", id, %{})
  defp change({:agent_forgotten, id}), do: agent_change("agent.forgotten", id, %{})

  defp change({:agent_forgotten, id, prefix}),
    do: agent_change("agent.forgotten", id, %{"under" => to_string(prefix)})

  defp change({:agent_moved, id, node}),
    do: agent_change("agent.moved", id, %{"node" => to_string(node)})

  defp change({:agent_cancelled, id}), do: agent_change("agent.cancelled", id, %{})

  defp change({:agent_cancelled, id, prefix}),
    do: agent_change("agent.cancelled", id, %{"under" => to_string(prefix)})

  defp change({:agent_cleared, id}), do: agent_change("agent.cleared", id, %{})

  defp change({:trigger_set, id, name}),
    do: agent_change("trigger.set", id, %{"trigger" => %{"name" => name}})

  defp change({:trigger_removed, id, name}),
    do: agent_change("trigger.removed", id, %{"trigger" => %{"name" => name}})

  defp change({:agents_reloaded, nodes}),
    do: {"agents.reloaded", "agents", %{"nodes" => Enum.map(nodes, &to_string/1)}}

  defp change({:room_bound, channel, room, agent, answers}) do
    data = %{
      "channel" => channel,
      "room" => room,
      "agent" => %{"id" => to_string(agent)},
      "answers" => to_string(answers)
    }

    {"room.bound", "rooms/#{channel}/#{room}", data}
  end

  defp change({:room_unbound, channel, room}),
    do: {"room.unbound", "rooms/#{channel}/#{room}", %{"channel" => channel, "room" => room}}

  defp change({:token_created, id, name, grant, for}) do
    data =
      %{
        "token" => %{"id" => id, "name" => name},
        "scope" => to_string(grant.scope),
        "can" => Enum.map(grant.can, &to_string/1)
      }
      |> Value.put("for", Value.principal(for))

    {"token.created", "tokens/" <> id, data}
  end

  defp change({:token_revoked, id}),
    do: {"token.revoked", "tokens/" <> id, %{"token" => %{"id" => id}}}

  defp change({:secret_stored, name, owner}), do: secret("secret.stored", name, owner)
  defp change({:secret_removed, name, owner}), do: secret("secret.removed", name, owner)

  defp agent_change(type, id, data),
    do: {type, "agents/#{id}", Map.put(data, "agent", %{"id" => to_string(id)})}

  # A deployment's secret is every agent's, and its owner goes unsaid.
  defp secret(type, name, owner) do
    data = Value.put(%{"secret" => %{"name" => name}}, "owner", owned_by(owner))
    {type, "secrets/" <> name, data}
  end

  defp owned_by(owner) do
    if owner == Prefix.all(), do: nil, else: to_string(owner)
  end

  # -- helpers -------------------------------------------------------------------

  defp in_run(type, event, run, data) do
    trace_id = event.source.trace.trace_id
    {type, "runs/" <> trace_id, Map.put(data, "run", Map.put(run, "id", trace_id))}
  end

  defp step_subject(event), do: "steps/" <> event.source.trace.span_id

  defp subagent(event, data) do
    case event.source.trace.name do
      nil -> data
      name -> Map.put(data, "agent", %{"name" => name})
    end
  end

  defp outcome(data, :ok), do: Map.put(data, "status", "ok")
  defp outcome(data, {:error, :interrupted}), do: Map.put(data, "status", "cancelled")

  defp outcome(data, {:error, reason}),
    do: data |> Map.put("status", "error") |> Map.put("error", Value.error(reason))

  defp answered(message_id, %ReqLLM.Response{message: %ReqLLM.Message{} = message}),
    do: Value.message(message, message_id)

  defp answered(message_id, _nothing), do: %{"id" => message_id}

  defp response(nil), do: nil

  defp response(%ReqLLM.Response{} = response) do
    %{"model" => response.model, "id" => response.id}
    |> Value.put("finish_reasons", response.finish_reason && [to_string(response.finish_reason)])
  end

  defp delta(type, text, opts) do
    message_id = Keyword.get(opts, :message_id)
    {type, "messages/#{message_id}", %{"message" => %{"id" => message_id}, "delta" => text}}
  end

  defp completed(id, name, result, replayed?, served_by, cost) do
    {status, value, error} = Value.result(result)

    call = if value == nil, do: %{"id" => id}, else: Value.capped(%{"id" => id}, "result", value)

    data =
      %{"tool" => %{"name" => name, "call" => call}, "status" => status, "replayed" => replayed?}
      |> Value.put("error", error)
      |> Value.put("served_by", Value.served(served_by))
      |> Value.put("cost", Value.cost(cost))

    {"tool_call.completed", "tool_calls/" <> id, data}
  end
end
