defmodule Wardrik.Operations.Types do
  @moduledoc """
  What each operation takes and answers in Elixir: its input from keyword lists and structs, and
  its output as structs, lists and `:ok`, in place of the protocol's JSON.
  """

  alias Wardrik.Agent
  alias Wardrik.Authorization
  alias Wardrik.Call
  alias Wardrik.ChannelResponse
  alias Wardrik.Connecting
  alias Wardrik.Connection
  alias Wardrik.Decision
  alias Wardrik.Definition
  alias Wardrik.Event
  alias Wardrik.Forgotten
  alias Wardrik.Interrupt
  alias Wardrik.MCPServer
  alias Wardrik.MCPServerAdded
  alias Wardrik.Message
  alias Wardrik.Nodes
  alias Wardrik.Page
  alias Wardrik.Runs
  alias Wardrik.Timeline
  alias Wardrik.Token
  alias Wardrik.TokenIssued
  alias Wardrik.Trigger
  alias Wardrik.Type

  @snapshots ~w(agent.read agent.define agent.clear)
  @decided ~w(agent.decide agent.approve agent.deny)
  @answered_nothing ~w(agent.cancel agent.forget agent.kill hook.deliver hook.deliver_with_secret)
  @triggers ~w(agent.trigger_set agent.trigger_remove)
  @pages ~w(agent.events events.list audit.list)

  @doc "Returns what a path names: the text given, or the id or name of the struct given."
  @spec path(String.t() | struct()) :: String.t()
  def path(text) when is_binary(text), do: text
  def path(%Agent{id: id}), do: id
  def path(%Interrupt{id: id}), do: id
  def path(%Call{id: id}), do: id
  def path(%Trigger{name: name}), do: name
  def path(%MCPServer{name: name}), do: name
  def path(%Connection{provider: provider}), do: provider
  def path(%Token{id: id}), do: id

  @doc "Turns `input`, as an Elixir caller gives it, into the operation's JSON input."
  @spec encode(String.t(), term()) :: map()
  def encode("agent.define", %Definition{} = definition), do: Definition.to_json(definition)
  def encode("agent.define", fields), do: fields |> Definition.new!() |> Definition.to_json()
  def encode("agent.ask", text) when is_binary(text), do: %{"content" => text}

  def encode("agent.decide", decisions) when is_map(decisions),
    do: %{"decisions" => Enum.map(decisions, &decision/1)}

  def encode(_id, []), do: %{}
  def encode(_id, input), do: Type.json(input)

  @doc "Turns the operation's JSON output into what an Elixir caller gets."
  @spec decode(String.t(), map() | nil) :: term()
  def decode(id, output) when id in @snapshots, do: {:ok, Agent.from_json(output)}

  def decode(id, %{"decisions" => decisions}) when id in @decided,
    do: {:ok, Enum.map(decisions, &Decision.from_json/1)}

  def decode(id, nil) when id in @answered_nothing, do: :ok
  def decode(id, output) when id in @pages, do: {:ok, Page.from_json(output)}

  def decode(id, %{"agent" => agent}) when id in ~w(agent.spawn agent.stop),
    do: {:ok, Agent.from_summary(agent)}

  def decode(id, output) when id in @triggers, do: {:ok, Trigger.from_json(output)}
  def decode("agent.ask", %{"message" => message}), do: {:ok, Message.from_json(message)}
  def decode("channel.deliver", output), do: {:ok, ChannelResponse.from_json(output)}
  def decode("agent.authorization", output), do: {:ok, Authorization.from_json(output)}
  def decode("agent.calls", %{"calls" => calls}), do: {:ok, Enum.map(calls, &Call.from_json/1)}

  def decode("agent.definition", %{"definition" => definition, "missing" => missing}),
    do: {:ok, Definition.from_json(definition), missing}

  def decode("agent.timeline", output), do: {:ok, Timeline.from_json(output)}
  def decode("agent.runs", output), do: {:ok, Runs.from_json(output)}

  def decode("agents.list", %{"agents" => agents}),
    do: {:ok, Enum.map(agents, &Agent.from_summary/1)}

  def decode("agents.cancel", %{"cancelled" => cancelled}), do: {:ok, cancelled}
  def decode("agents.forget", output), do: {:ok, Forgotten.from_json(output)}

  def decode("interrupts.list", %{"interrupts" => listed}),
    do: {:ok, Enum.map(listed, &Interrupt.from_listed/1)}

  def decode("events.head", %{"cursor" => cursor}), do: {:ok, cursor}

  def decode("tokens.list", %{"tokens" => tokens}),
    do: {:ok, Enum.map(tokens, &Token.from_json/1)}

  def decode("tokens.create", output), do: {:ok, TokenIssued.from_json(output)}
  def decode("tokens.revoke", output), do: {:ok, Token.from_json(output)}
  def decode("deployment.reload", %{"reloaded" => nodes}), do: {:ok, nodes}
  def decode("deployment.nodes", output), do: {:ok, Nodes.from_json(output)}
  def decode("agent.move", %{"agent" => agent}), do: {:ok, Agent.from_summary(agent)}

  def decode("connections.list", %{"connections" => connections}),
    do: {:ok, Enum.map(connections, &Connection.from_json/1)}

  def decode("connections.connect", output), do: {:ok, Connecting.from_json(output)}
  def decode("connections.disconnect", output), do: {:ok, Connection.from_json(output)}

  def decode("mcp_servers.list", %{"servers" => servers}),
    do: {:ok, Enum.map(servers, &MCPServer.from_json/1)}

  def decode("mcp_servers.add", output), do: {:ok, MCPServerAdded.from_json(output)}
  def decode("mcp_servers.remove", output), do: {:ok, MCPServer.from_json(output)}

  @doc "Turns a streamed event and its cursor into what an Elixir caller gets."
  @spec event({map(), String.t()}) :: {Event.t(), String.t()}
  def event({event, cursor}), do: {Event.from_json(event), cursor}

  defp decision({id, :approve}), do: %{"id" => id, "decision" => "approve"}

  defp decision({id, {:approve, note}}),
    do: %{"id" => id, "decision" => "approve", "note" => note}

  defp decision({id, {:deny, reason}}),
    do: %{"id" => id, "decision" => "reject", "reason" => reason}
end
