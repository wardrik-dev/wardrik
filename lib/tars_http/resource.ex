defmodule TarsHTTP.Resource do
  @moduledoc """
  What the HTTP API answers with, as maps `JSON.encode!/1` takes.

  Names follow the event data's: OpenTelemetry's attribute names without
  their `gen_ai.` prefix, as nested objects, and messages and interrupts in
  the shapes `Tars.Event.Codec.Value` gives them.

  ## An agent, listed

      {"id": "acme/ops/triage", "name": "triage", "status": "parked",
       "pending": 0, "node": "tars@box1", "outcome": "ok"}

  ## An agent's snapshot

      {"agent": {"id": "acme/ops/triage", "name": "triage"},
       "conversation": {"id": "acme/ops/triage/5f1c…"},
       "status": "parked", "pending": 0,
       "request": {"model": "claude-sonnet-5"}, "provider": {"name": "anthropic"},
       "run": {"id": "4bf92f35…"},
       "interrupts": [{"id": "toolu_01", "reason": "tool_approval", "message": "…", "tool_call_id": "toolu_01"}],
       "messages": [{"role": "user", "parts": [{"type": "text", "content": "…"}]}],
       "outcome": "ok", "sequence": 41}

  `run` is `null` between runs, and `sequence` is the last event the agent's
  log has written: read and follow the log from there.

  ## An error

      {"error": {"type": "not_found", "message": "No agent runs under acme/ops/triage."}}
  """

  alias Tars.Agent.Snapshot
  alias Tars.Event.Codec.Value
  alias Tars.Fleet.Member

  @doc "An agent as the fleet lists it."
  @spec agent(Member.t()) :: map()
  def agent(%Member{} = member) do
    %{
      "id" => member.key,
      "name" => member.name,
      "status" => to_string(member.status),
      "pending" => member.pending,
      "node" => to_string(member.node)
    }
    |> Value.put("outcome", member.outcome && to_string(member.outcome))
  end

  @doc "An agent's snapshot, for the agent under `key`."
  @spec snapshot(String.t(), Snapshot.t()) :: map()
  def snapshot(key, %Snapshot{} = snapshot) do
    {provider, model} = Value.model(snapshot.status.model)

    %{
      "agent" => %{"id" => key, "name" => key |> String.split("/") |> List.last()},
      "conversation" => %{"id" => key <> "/" <> snapshot.generation},
      "status" => to_string(snapshot.status.state),
      "pending" => snapshot.status.pending,
      "request" => %{"model" => model},
      "run" => snapshot.trace_id && %{"id" => snapshot.trace_id},
      "interrupts" => Enum.map(snapshot.parked, &Value.interrupt/1),
      "messages" => Enum.map(snapshot.context.messages, &Value.message/1),
      "outcome" => snapshot.outcome && to_string(snapshot.outcome),
      "sequence" => snapshot.sequence
    }
    |> Value.put("provider", provider && %{"name" => provider})
  end

  @doc "An error of `type`, saying what went wrong, with any other fields beside."
  @spec error(String.t(), String.t(), map()) :: map()
  def error(type, message, fields \\ %{}),
    do: %{"error" => Map.merge(%{"type" => type, "message" => message}, fields)}
end
