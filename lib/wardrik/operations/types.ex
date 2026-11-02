defmodule Wardrik.Operations.Types do
  @moduledoc """
  Converts each operation's input and output between Elixir and the protocol's JSON.

  Input is keyword lists and structs. Output is structs, lists and `:ok`.
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
  alias Wardrik.NotifyTarget
  alias Wardrik.Page
  alias Wardrik.Provider
  alias Wardrik.Runs
  alias Wardrik.Timeline
  alias Wardrik.Trigger
  alias Wardrik.Type

  @snapshots ~w(agent.read agent.define agent.clear)
  @decided ~w(agent.decide agent.approve agent.deny)
  @answered_nothing ~w(agent.cancel agent.forget agent.kill hook.deliver hook.deliver_with_secret)
  @triggers ~w(agent.trigger_set agent.trigger_remove)
  @pages ~w(agent.events events.list audit.list)

  @structs %{
    "channel.deliver" => ChannelResponse,
    "agent.authorization" => Authorization,
    "agent.timeline" => Timeline,
    "agent.runs" => Runs,
    "agents.forget" => Forgotten,
    "deployment.nodes" => Nodes,
    "connections.connect" => Connecting,
    "connections.disconnect" => Connection,
    "mcp_servers.add" => MCPServerAdded,
    "mcp_servers.remove" => MCPServer,
    "providers.add" => Provider,
    "providers.remove" => Provider,
    "notify_targets.add" => NotifyTarget,
    "notify_targets.remove" => NotifyTarget
  }

  @lists %{
    "agent.calls" => {"calls", Call, :from_json},
    "agents.list" => {"agents", Agent, :from_summary},
    "interrupts.list" => {"interrupts", Interrupt, :from_listed},
    "connections.list" => {"connections", Connection, :from_json},
    "mcp_servers.list" => {"servers", MCPServer, :from_json},
    "providers.list" => {"providers", Provider, :from_json},
    "notify_targets.list" => {"targets", NotifyTarget, :from_json}
  }

  @listed Map.keys(@lists)

  @doc "Returns the path segment for `value`: a string as given, or a struct's ID or name."
  @spec path(String.t() | struct()) :: String.t()
  def path(text) when is_binary(text), do: text
  def path(%Agent{id: id}), do: id
  def path(%Interrupt{id: id}), do: id
  def path(%Call{id: id}), do: id
  def path(%Trigger{name: name}), do: name
  def path(%MCPServer{name: name}), do: name
  def path(%Provider{name: name}), do: name
  def path(%NotifyTarget{name: name}), do: name
  def path(%Connection{provider: provider}), do: provider

  @doc "Converts an Elixir caller's `input` to the operation's JSON input."
  @spec encode(String.t(), term()) :: map()
  def encode("agent.define", %Definition{} = definition), do: Definition.to_json(definition)
  def encode("agent.define", fields), do: fields |> Definition.new!() |> Definition.to_json()
  def encode("agent.ask", text) when is_binary(text), do: %{"content" => text}

  def encode("agent.decide", decisions) when is_map(decisions),
    do: %{"decisions" => Enum.map(decisions, &decision/1)}

  def encode(_id, []), do: %{}
  def encode(_id, input), do: Type.json(input)

  @doc """
  Converts an Elixir caller's `input` to the operation's JSON input, taking the path parameters
  `keys` from it. Raises `KeyError` if one is missing.
  """
  @spec named(String.t(), keyword(), [atom()]) :: map()
  def named(id, input, keys) do
    path = Map.new(keys, &{Atom.to_string(&1), path(Keyword.fetch!(input, &1))})
    Map.merge(encode(id, Keyword.drop(input, keys)), path)
  end

  @doc "Converts the operation's JSON output to what an Elixir caller gets."
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

  @doc "Converts a streamed event and its cursor to `{%Wardrik.Event{}, cursor}`."
  @spec event({map(), String.t()}) :: {Event.t(), String.t()}
  def event({event, cursor}), do: {Event.from_json(event), cursor}

  defp decision({id, :approve}), do: %{"id" => id, "decision" => "approve"}

  defp decision({id, {:approve, note}}),
    do: %{"id" => id, "decision" => "approve", "note" => note}

  defp decision({id, {:deny, reason}}),
    do: %{"id" => id, "decision" => "reject", "reason" => reason}
end
