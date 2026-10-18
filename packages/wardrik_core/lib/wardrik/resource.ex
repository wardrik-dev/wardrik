defmodule Wardrik.Resource do
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
  alias Wardrik.Connections.Connection
  alias Wardrik.Deployment.Nodes
  alias Wardrik.Event.Codec.Value
  alias Wardrik.Fleet.Member
  alias Wardrik.Servers.Server
  alias Wardrik.Tokens.Token

  @doc "An agent as the fleet lists it."
  @spec agent(Member.t()) :: map()
  def agent(%Member{} = member) do
    %{
      "id" => to_string(member.id),
      "name" => member.id.name,
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
      "agent" => %{"id" => to_string(id), "name" => id.name},
      "conversation" => %{"id" => "#{id}/#{snapshot.generation}"},
      "status" => to_string(snapshot.status.state),
      "pending" => snapshot.status.pending,
      "request" => %{"model" => model},
      "run" => snapshot.trace_id && %{"id" => snapshot.trace_id},
      "interrupts" => Enum.map(snapshot.parked, &Value.interrupt/1),
      "messages" => Enum.map(snapshot.context.messages, &Value.message/1),
      "labels" => snapshot.labels,
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
  A token as `Wardrik.Tokens` keeps it, never its secret: what its grant
  reaches, and allows; the names of the hooks of its ceiling, where it can
  define agents; and the person it acts for, where it acts for one.
  """
  @spec token(Token.t()) :: map()
  def token(%Token{} = token) do
    %{
      "id" => token.id,
      "name" => token.name,
      "scope" => to_string(token.grant.scope),
      "can" => Enum.map(token.grant.can, &to_string/1),
      "created_at" => DateTime.to_iso8601(token.created_at)
    }
    |> Value.put(
      "ceiling",
      if(:define in token.grant.can, do: Enum.map(token.grant.ceiling, & &1.name))
    )
    |> Value.put("for", token.principal && Wardrik.Principal.id(token.principal))
  end

  @doc "The connections an owner is offered, and who holds each, where anyone does."
  @spec connections([Connection.t()]) :: map()
  def connections(connections), do: %{"connections" => Enum.map(connections, &connection/1)}

  @doc "One connection: its provider, and who holds it, where anyone does."
  @spec connection(Connection.t()) :: map()
  def connection(%Connection{provider: provider, held_by: held_by}),
    do: Value.put(%{"provider" => provider}, "held_by", held_by && to_string(held_by))

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
  @spec interrupts([{Wardrik.AgentID.t(), {Wardrik.Tool.call(), String.t()}}]) :: map()
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
          Wardrik.AgentID.t() => :forgotten | {:kept, String.t()} | {:failed, String.t()}
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
  @spec cancelled([Wardrik.AgentID.t()]) :: map()
  def cancelled(ids), do: %{"cancelled" => Enum.map(ids, &to_string/1)}

  @doc """
  A page of an export: its events, the `next` that moves the export past
  them, and where a log was trimmed before the export got to it.
  """
  @spec export(Wardrik.Event.Export.t()) :: map()
  def export(%Wardrik.Event.Export{} = page) do
    %{
      "events" => page.events,
      "next" => page.next,
      "gaps" =>
        for(
          gap <- page.gaps,
          do: %{"log" => to_string(gap.log), "after" => gap.after, "oldest" => gap.oldest}
        )
    }
  end

  @types %{
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
