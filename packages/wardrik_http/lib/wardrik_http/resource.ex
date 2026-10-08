defmodule WardrikHTTP.Resource do
  @moduledoc """
  What the HTTP API answers with, as maps `JSON.encode!/1` takes.

  Names follow the event data's: OpenTelemetry's attribute names without
  their `gen_ai.` prefix, as nested objects, and messages and interrupts in
  the shapes `Wardrik.Event.Codec.Value` gives them.

  ## An agent, listed

      {"id": "acme/triage", "name": "triage", "status": "parked",
       "pending": 0, "node": "wardrik@box1", "outcome": "ok"}

  `id` is the agent's ID, and its segments are the agent's path under
  `/v1/agents/`, each encoded on its own.

  ## An agent's snapshot

      {"agent": {"id": "acme/triage", "name": "triage"},
       "conversation": {"id": "acme/triage/5f1c…"},
       "status": "parked", "pending": 0,
       "request": {"model": "claude-sonnet-5"}, "provider": {"name": "anthropic"},
       "run": {"id": "4bf92f35…"},
       "interrupts": [{"id": "toolu_01", "reason": "tool_approval", "message": "…", "tool_call_id": "toolu_01"}],
       "messages": [{"role": "user", "parts": [{"type": "text", "content": "…"}]}],
       "outcome": "ok", "sequence": 41}

  `run` is `null` between runs, and `sequence` is the last event the agent's
  log has written: read and follow the log from there.

  ## An error

      {"error": {"type": "not_found", "message": "No agent runs under acme/triage."}}
  """

  alias Wardrik.Agent.Snapshot
  alias Wardrik.Event.Codec.Value
  alias Wardrik.Fleet.Member

  @doc "An agent as the fleet lists it."
  @spec agent(Member.t()) :: map()
  def agent(%Member{} = member) do
    %{
      "id" => to_string(member.id),
      "name" => member.id.name,
      "status" => to_string(member.status),
      "pending" => member.pending,
      "node" => to_string(member.node)
    }
    |> Value.put("outcome", member.outcome && to_string(member.outcome))
  end

  @doc "An agent's snapshot, for the agent `id`."
  @spec snapshot(Wardrik.AgentID.t(), Snapshot.t()) :: map()
  def snapshot(%Wardrik.AgentID{} = id, %Snapshot{} = snapshot) do
    {provider, model} = Value.model(snapshot.status.model)

    %{
      "agent" => %{"id" => to_string(id), "name" => id.name},
      "conversation" => %{"id" => "#{id}/#{snapshot.generation}"},
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

  @doc "Where a person authorizes a waiting call: the page, and the code to enter where one is needed."
  @spec authorization(Wardrik.Call.Ask.link()) :: map()
  def authorization(%{url: url} = link) do
    case link[:code] do
      code when is_binary(code) -> %{"url" => url, "code" => code}
      _none -> %{"url" => url}
    end
  end

  @doc "An error of `type`, saying what went wrong, with any other fields beside."
  @spec error(String.t(), String.t(), map()) :: map()
  def error(type, message, fields \\ %{}),
    do: %{"error" => Map.merge(%{"type" => type, "message" => message}, fields)}
end
