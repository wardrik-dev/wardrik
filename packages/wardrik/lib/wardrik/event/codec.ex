defmodule Wardrik.Event.Codec do
  @moduledoc """
  A `Wardrik.Event` as a CloudEvent: the map, with string keys, that the event
  log stores and the HTTP API sends.

      {:ok, cloud_event} = Wardrik.Event.Codec.encode(event, sequence: 41)

  ## The envelope

  CloudEvents 1.0 in structured JSON:

    * `specversion` - `"1.0"`
    * `id` - the event's UUIDv7
    * `source` - the agent, as `wardrik://<deployment>/agents/<key>`, where the
      deployment is `config :wardrik, :deployment`, `"local"` by default
    * `type` - `wardrik.` then a noun and a past-tense verb, the same string as
      the event's OpenTelemetry event name
    * `subject` - what the event is about: `runs/…`, `messages/…`,
      `tool_calls/…`, `interrupts/…`, `steps/…` or `agents/…`
    * `time` - RFC 3339 in UTC, to the microsecond
    * `datacontenttype` - `"application/json"`
    * `dataschema` - `urn:wardrik:schema:v1:<type>`, the JSON Schema the data
      follows, which `wardrik_protocol` holds
    * `sequence` - CloudEvents' sequence extension: the event's place in its
      agent's log, zero-padded to #{12} digits, for a durable event given one
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
  """

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
  @agent [:message_queued, :agent_started, :context_compacted, :context_cleared, :schedule_fired]
  @steps [:span_started, :span_finished, :delegation_started, :delegation_finished]
  @messages [:model_started, :model_finished, :result, :thinking]

  @doc """
  The CloudEvent for `event`, or `:skip` for one that is not sent.

  Options:

    * `:sequence` - the event's place in its agent's log
    * `:message_id` - the message a text or reasoning delta belongs to
  """
  @spec encode(Event.t(), keyword()) :: {:ok, map()} | :skip
  def encode(%Event{} = event, opts \\ []) do
    if Event.type(event) in @skipped do
      :skip
    else
      {type, subject, data} = describe(Event.type(event), event, opts)
      {:ok, envelope(event, type, subject, data, opts)}
    end
  end

  @doc "Whether events of an internal type go in the log, rather than being streamed alone."
  @spec durable?(atom()) :: boolean()
  def durable?(type) when is_atom(type), do: type not in @live and type not in @skipped

  @doc "The CloudEvents `source` of an agent's events."
  @spec source(Event.Bus.agent_id()) :: String.t()
  def source(agent_id),
    do: "wardrik://#{Application.get_env(:wardrik, :deployment, "local")}/agents/#{agent_id}"

  @doc "The URI of the JSON Schema for a CloudEvent type's data."
  @spec schema(String.t()) :: String.t()
  def schema("wardrik." <> type), do: "urn:wardrik:schema:v1:" <> type

  defp envelope(event, type, subject, data, opts) do
    trace = event.source.trace

    %{
      "specversion" => "1.0",
      "id" => event.id,
      "source" => source(event.source.agent_id),
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

  defp run({:turn_started, messages}, event, _opts),
    do: in_run("run.started", event, %{"message_ids" => Enum.map(messages, & &1.id)}, %{})

  defp run({:turn_finished, messages}, event, _opts),
    do: in_run("run.completed", event, %{}, %{"messages" => Enum.map(messages, &Value.message/1)})

  defp run({:turn_failed, reason}, event, _opts),
    do: in_run("run.failed", event, %{}, %{"error" => Value.error(reason)})

  defp run({:turn_interrupted, stats}, event, _opts) do
    in_run("run.cancelled", event, %{}, %{
      "dropped" => stats.dropped,
      "kept" => stats.kept,
      "resolution" => to_string(stats.resolution),
      "duration_ms" => stats.elapsed_ms
    })
  end

  defp run({:turn_parked, calls}, event, _opts),
    do:
      in_run("run.interrupted", event, %{}, %{
        "interrupts" => Enum.map(calls, &Value.interrupt/1)
      })

  defp run({:turn_resumed, _decisions}, event, _opts),
    do: in_run("run.resumed", event, %{}, %{})

  defp run({:deadline_reached, count}, event, _opts),
    do: in_run("run.deadline_exceeded", event, %{}, %{"message_count" => count})

  defp run({:call_decided, call_id, decision, by}, _event, _opts) do
    {verdict, reason} =
      case decision do
        :approve -> {"approved", nil}
        {:deny, reason} -> {"rejected", reason}
      end

    data =
      %{"interrupt" => %{"id" => call_id}, "decision" => verdict}
      |> Value.put("reason", reason)
      |> Value.put("resolved_by", Value.principal(by))

    {"interrupt.resolved", "interrupts/" <> call_id, data}
  end

  # -- the agent and its conversation --------------------------------------------

  defp agent({:message_queued, message}, _event, _opts),
    do: {"message.created", "messages/" <> message.id, %{"message" => Value.user(message)}}

  defp agent({:agent_started, node, status, generation}, event, _opts) do
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

  defp agent({:context_compacted, stats}, event, _opts) do
    {"conversation.compacted", "agents/#{event.source.agent_id}",
     %{
       "messages_before" => stats.messages_before,
       "messages_after" => stats.messages_after,
       "tokens_before" => stats.tokens_before,
       "tokens_after" => stats.tokens_after
     }}
  end

  defp agent({:context_cleared, dropped}, event, _opts),
    do:
      {"conversation.cleared", "agents/#{event.source.agent_id}", %{"messages_before" => dropped}}

  defp agent({:schedule_fired, name, outcome}, event, _opts) do
    {"schedule.triggered", "agents/#{event.source.agent_id}",
     %{"schedule" => %{"name" => name}, "status" => to_string(outcome)}}
  end

  # -- steps and subagents -------------------------------------------------------

  defp step({:span_started, name}, event, _opts),
    do: {"step.started", step_subject(event), %{"step" => %{"name" => name}}}

  defp step({:span_finished, outcome, ms}, event, _opts),
    do: {"step.completed", step_subject(event), outcome(%{"duration_ms" => ms}, outcome)}

  defp step({:delegation_started, prompt}, event, _opts),
    do: {"subagent.started", step_subject(event), subagent(event, %{"prompt" => prompt})}

  defp step({:delegation_finished, {:ok, text}, ms}, event, _opts) do
    data = %{"message" => Value.assistant(text), "duration_ms" => ms}
    {"subagent.completed", step_subject(event), subagent(event, data)}
  end

  defp step({:delegation_finished, {:error, reason}, ms}, event, _opts) do
    data = %{"error" => Value.error(reason), "duration_ms" => ms}
    {"subagent.failed", step_subject(event), subagent(event, data)}
  end

  # -- assistant messages --------------------------------------------------------

  defp message({:model_started, message_id, spec, decided_by}, _event, _opts) do
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

  defp message({:model_finished, message_id, outcome, ms, response}, _event, _opts) do
    data =
      %{"message" => answered(message_id, response), "duration_ms" => ms}
      |> outcome(outcome)
      |> Value.put("response", response(response))
      |> Value.put("usage", response && Value.usage(response.usage))

    {"message.completed", "messages/" <> message_id, data}
  end

  defp message({:result, text}, _event, opts), do: delta("message.delta", text, opts)
  defp message({:thinking, text}, _event, opts), do: delta("reasoning.delta", text, opts)

  # -- tool calls ----------------------------------------------------------------

  defp tool({:tool_started, id, name, arguments, key, decided_by}, _event, _opts) do
    call =
      %{"id" => id, "idempotency_key" => key}
      |> Value.capped("arguments", Value.json(arguments))

    {"tool_call.started", "tool_calls/" <> id,
     %{"tool" => %{"name" => name, "call" => call}, "decided" => Value.decided(decided_by)}}
  end

  defp tool({:tool_finished, id, name, result, served_by}, _event, _opts),
    do: completed(id, name, result, false, served_by)

  defp tool({:tool_replayed, id, name, result}, _event, _opts),
    do: completed(id, name, result, true, nil)

  defp tool({:tool_denied, id, name, reason, decided_by}, _event, _opts) do
    {"tool_call.denied", "tool_calls/" <> id,
     %{
       "tool" => %{"name" => name, "call" => %{"id" => id}},
       "reason" => reason,
       "decided" => Value.decided(decided_by)
     }}
  end

  defp tool({:tool_progress, id, name, progress, total}, _event, _opts) do
    data =
      %{"tool" => %{"name" => name, "call" => %{"id" => id}}, "progress" => progress}
      |> Value.put("total", total)

    {"tool_call.progress", "tool_calls/" <> id, data}
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

  defp completed(id, name, result, replayed?, served_by) do
    {status, value, error} = Value.result(result)

    call = if value == nil, do: %{"id" => id}, else: Value.capped(%{"id" => id}, "result", value)

    data =
      %{"tool" => %{"name" => name, "call" => call}, "status" => status, "replayed" => replayed?}
      |> Value.put("error", error)
      |> Value.put("served_by", Value.served(served_by))

    {"tool_call.completed", "tool_calls/" <> id, data}
  end
end
