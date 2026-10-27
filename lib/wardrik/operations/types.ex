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
  alias Wardrik.Secret
  alias Wardrik.Spend
  alias Wardrik.Timeline
  alias Wardrik.Token
  alias Wardrik.TokenIssued
  alias Wardrik.Trigger
  alias Wardrik.Type

  @snapshots ~w(agent.read agent.define agent.clear)
  @decided ~w(agent.decide agent.approve agent.deny)
  @answered_nothing ~w(agent.cancel agent.forget agent.kill hook.deliver hook.deliver_with_secret
                       secrets.put secrets.delete)
  @triggers ~w(agent.trigger_set agent.trigger_remove)
  @pages ~w(agent.events events.list audit.list)

  @structs %{
    "channel.deliver" => ChannelResponse,
    "agent.authorization" => Authorization,
    "agent.timeline" => Timeline,
    "agent.runs" => Runs,
    "agents.forget" => Forgotten,
    "tokens.create" => TokenIssued,
    "tokens.revoke" => Token,
    "deployment.nodes" => Nodes,
    "connections.connect" => Connecting,
    "connections.disconnect" => Connection,
    "mcp_servers.add" => MCPServerAdded,
    "mcp_servers.remove" => MCPServer
  }

  @lists %{
    "agent.calls" => {"calls", Call, :from_json},
    "agents.list" => {"agents", Agent, :from_summary},
    "interrupts.list" => {"interrupts", Interrupt, :from_listed},
    "tokens.list" => {"tokens", Token, :from_json},
    "connections.list" => {"connections", Connection, :from_json},
    "mcp_servers.list" => {"servers", MCPServer, :from_json},
    "secrets.list" => {"secrets", Secret, :from_json},
    "ceilings.list" => {"ceilings", Spend, :from_json}
  }

  @listed Map.keys(@lists)

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
  def decode(id, output) when id in @triggers, do: {:ok, Trigger.from_json(output)}

  def decode(id, output) when is_map_key(@structs, id),
    do: {:ok, Map.fetch!(@structs, id).from_json(output)}

  def decode(id, output) when id in @listed do
    {key, type, read} = Map.fetch!(@lists, id)
    {:ok, Enum.map(Map.fetch!(output, key), &apply(type, read, [&1]))}
  end

  def decode(id, %{"agent" => agent}) when id in ~w(agent.spawn agent.stop agent.move),
    do: {:ok, Agent.from_summary(agent)}

  def decode("agent.ask", %{"message" => message}), do: {:ok, Message.from_json(message)}

  def decode("agent.definition", %{"definition" => definition, "missing" => missing}),
    do: {:ok, Definition.from_json(definition), missing}

  def decode("agents.cancel", %{"cancelled" => cancelled}), do: {:ok, cancelled}
  def decode("events.head", %{"cursor" => cursor}), do: {:ok, cursor}
  def decode("deployment.reload", %{"reloaded" => nodes}), do: {:ok, nodes}

  @doc "Turns a streamed event and its cursor into what an Elixir caller gets."
  @spec event({map(), String.t()}) :: {Event.t(), String.t()}
  def event({event, cursor}), do: {Event.from_json(event), cursor}

  defp decision({id, :approve}), do: %{"id" => id, "decision" => "approve"}

  defp decision({id, {:approve, note}}),
    do: %{"id" => id, "decision" => "approve", "note" => note}

  defp decision({id, {:deny, reason}}),
    do: %{"id" => id, "decision" => "reject", "reason" => reason}
end
