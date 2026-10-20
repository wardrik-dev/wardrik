defmodule Wardrik.JSON do
  @moduledoc """
  What `Wardrik`'s functions answer, as JSON, as maps `JSON.encode!/1`
  takes: the shapes every surface answers in, as the HTTP API does.

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
       "activity": {"doing": [{"type": "wardrik.run.interrupted", "interrupts": […]}],
                    "since": "2026-10-18T12:00:00.000000Z", "pending": 0},
       "request": {"model": "claude-sonnet-5"}, "provider": {"name": "anthropic"},
       "run": {"id": "4bf92f35…"},
       "interrupts": [{"id": "toolu_01", "reason": "tool_approval", "message": "…", "tool_call_id": "toolu_01"}],
       "messages": [{"role": "user", "parts": [{"type": "text", "content": "…"}]}],
       "outcome": "ok", "cursor": "eyJhY21lL2FnZW50L3RyaWFnZSI6NDF9"}

  `run` is `null` between runs, and `cursor` is where the agent's log
  stands: read and follow it from there. `activity` is what
  the agent is doing now, as `wardrik.activity.changed` says it, live, from
  then on.

  ## An error

      {"error": {"type": "not_found", "message": "No agent runs under acme/triage."}}
  """

  alias Wardrik.Agent.Snapshot
  alias Wardrik.Connections.Connection
  alias Wardrik.Deployment.Nodes
  alias Wardrik.Event.Codec.Value
  alias Wardrik.Fleet.Member
  alias Wardrik.Servers.Server
  alias Wardrik.Tokens.Entry

  @doc "An agent as the fleet lists it."
  @spec agent(Member.t()) :: map()
  def agent(%Member{} = member) do
    %{
      "id" => to_string(member.id),
      "name" => Wardrik.AgentAddress.agent(member.id).name,
      "status" => to_string(member.status),
      "pending" => member.pending,
      "asleep" => member.asleep
    }
    |> Value.put("node", member.node && to_string(member.node))
    |> Value.put("outcome", member.outcome && to_string(member.outcome))
  end

  @doc "An agent's snapshot."
  @spec snapshot(Snapshot.t()) :: map()
  def snapshot(%Snapshot{agent: id} = snapshot) do
    {provider, model} = Value.model(snapshot.status.model)

    %{
      "agent" => %{"id" => to_string(id), "name" => Wardrik.AgentAddress.agent(id).name},
      "conversation" => %{"id" => "#{id}/#{snapshot.generation}"},
      "status" => to_string(snapshot.status.state),
      "pending" => snapshot.status.pending,
      "activity" => Value.activity(snapshot.status.activity),
      "request" => %{"model" => model},
      "run" => snapshot.trace_id && %{"id" => snapshot.trace_id},
      "interrupts" => Enum.map(snapshot.parked, &Value.interrupt/1),
      "messages" => Enum.map(snapshot.history.messages, &Value.message/1),
      "labels" => snapshot.labels,
      "outcome" => snapshot.outcome && to_string(snapshot.outcome),
      "cursor" => snapshot.cursor
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

  @doc "The deployment's nodes, each with how many agents run on it, and how many sleep on none."
  @spec nodes(Nodes.t()) :: map()
  def nodes(%Nodes{nodes: nodes, asleep: asleep}) do
    %{
      "nodes" =>
        for({node, agents} <- nodes, do: %{"name" => to_string(node), "agents" => agents}),
      "asleep" => asleep
    }
  end

  @doc """
  A token as `Wardrik.Tokens` keeps it, never its secret: its id and name,
  whom it acts for, what it allows on what, the policy it names, when it
  was made, and when it expires.
  """
  @spec token(Entry.t()) :: map()
  def token(%Entry{} = entry) do
    entry.token
    |> Value.token()
    |> Map.merge(%{
      "id" => entry.id,
      "name" => entry.name,
      "created_at" => DateTime.to_iso8601(entry.created_at)
    })
  end

  @doc "A token just made, with the secret that presents it, given this once."
  @spec token_created(Entry.t()) :: map()
  def token_created(%Entry{secret: secret} = entry),
    do: %{"token" => token(entry), "secret" => secret}

  @doc "Every token a host keeps."
  @spec tokens([Entry.t()]) :: map()
  def tokens(entries), do: %{"tokens" => Enum.map(entries, &token/1)}

  @doc "The connections an owner is offered, and whether they hold each."
  @spec connections([Connection.t()]) :: map()
  def connections(connections), do: %{"connections" => Enum.map(connections, &connection/1)}

  @doc "One connection: its provider, and whether the owner holds it."
  @spec connection(Connection.t()) :: map()
  def connection(%Connection{provider: provider, connected: connected}),
    do: %{"provider" => provider, "connected" => connected}

  @doc "A connection asked for: held already, or where to authorize it."
  @spec connecting(Connection.t()) :: map()
  def connecting(%Connection{provider: provider, authorization: nil}),
    do: %{"provider" => provider, "connected" => true}

  def connecting(%Connection{provider: provider, authorization: link}),
    do: %{"provider" => provider, "connected" => false, "authorization" => authorization(link)}

  @doc "The MCP servers an owner added, each by its name, URL and how its agents sign in."
  @spec servers([Server.t()]) :: map()
  def servers(servers), do: %{"servers" => Enum.map(servers, &server/1)}

  @doc "One MCP server an owner added: its name, URL and how its agents sign in."
  @spec server(Server.t()) :: map()
  def server(%Server{name: name, url: url, auth: auth}),
    do: %{"name" => name, "url" => url, "auth" => auth}

  @doc "A server added: its agents can call it now, or once someone signs in where it says."
  @spec server_added(Server.t()) :: map()
  def server_added(%Server{name: name, authorization: nil}),
    do: %{"server" => name, "connected" => true}

  def server_added(%Server{name: name, authorization: link}),
    do: %{"server" => name, "connected" => false, "authorization" => authorization(link)}

  @doc "The calls agents wait on a person for, each as an interrupt with the agent it is for."
  @spec interrupts([{Wardrik.AgentAddress.t(), {Wardrik.Tool.call(), String.t()}}]) :: map()
  def interrupts(parked) do
    %{
      "interrupts" =>
        for(
          {id, waiting} <- parked,
          do: Map.put(Value.interrupt(waiting), "agent", %{"id" => to_string(id)})
        )
    }
  end

  @doc """
  What a forget did, as `%{id => outcome}`: the agents removed, those kept
  with why, and those not removed with why, each by ID.
  """
  @spec forgotten(%{
          Wardrik.AgentAddress.t() => :forgotten | {:kept, String.t()} | {:failed, String.t()}
        }) :: map()
  def forgotten(outcomes) do
    sorted = Enum.sort_by(outcomes, fn {id, _outcome} -> to_string(id) end)

    %{
      "forgotten" => for({id, :forgotten} <- sorted, do: to_string(id)),
      "kept" => reasons(for {id, {:kept, why}} <- sorted, do: {id, why}),
      "failed" => reasons(for {id, {:failed, why}} <- sorted, do: {id, why})
    }
  end

  defp reasons(pairs), do: for({id, why} <- pairs, do: %{"id" => to_string(id), "why" => why})

  @doc """
  The decisions taken on the calls an agent waits on, each by its id:
  `approved` or `rejected`.
  """
  @spec decisions(%{String.t() => :approve | {:approve | :deny, String.t()}}) :: map()
  def decisions(decisions) do
    %{
      "decisions" =>
        for(
          {id, decision} <- Enum.sort(decisions),
          do: %{"id" => id, "decision" => verdict(decision)}
        )
    }
  end

  defp verdict({:deny, _reason}), do: "rejected"
  defp verdict(_approved), do: "approved"

  @doc "The tool calls an agent is running, each with how long it has run."
  @spec calls([%{call_id: String.t(), name: String.t(), elapsed_ms: non_neg_integer()}]) ::
          map()
  def calls(calls) do
    %{
      "calls" =>
        for(
          call <- calls,
          do: %{"id" => call.call_id, "name" => call.name, "elapsed_ms" => call.elapsed_ms}
        )
    }
  end

  @doc "The agents a cancel stopped."
  @spec cancelled([Wardrik.AgentAddress.t()]) :: map()
  def cancelled(ids), do: %{"cancelled" => Enum.map(ids, &to_string/1)}

  @types %{
    unauthorized: "unauthorized",
    not_found: "not_found",
    forbidden: "forbidden",
    invalid: "invalid_request",
    conflict: "conflict",
    gap: "gap",
    unsupported: "not_supported",
    unavailable: "unavailable"
  }

  @doc "An operation's `Wardrik.Error`, as every surface answers it."
  @spec error(Wardrik.Error.t()) :: map()
  def error(%Wardrik.Error{type: type, message: message, details: details}),
    do: error(Map.fetch!(@types, type), message, details)

  @doc "An error of `type`, saying what went wrong, with any other fields beside."
  @spec error(String.t(), String.t(), map()) :: map()
  def error(type, message, fields \\ %{}),
    do: %{"error" => Map.merge(%{"type" => type, "message" => message}, fields)}
end
