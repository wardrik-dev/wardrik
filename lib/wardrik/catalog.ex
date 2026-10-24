defmodule Wardrik.Catalog do
  @moduledoc """
  The catalog joins each operation of `WardrikProtocol` to the function that does it, and to its
  input schema, built once. Every surface runs operations through it, with `Wardrik.run/3`.
  """

  alias Wardrik.Operations.Agent
  alias Wardrik.Operations.Agents
  alias Wardrik.Operations.Channels
  alias Wardrik.Operations.Deployment
  alias Wardrik.Operations.Lifecycle
  alias Wardrik.Operations.Owners
  alias Wardrik.Operations.Tokens
  alias Wardrik.Operations.Triggers

  @enforce_keys [:operations, :handlers, :streams]
  defstruct @enforce_keys

  @type handler() :: (Wardrik.Scope.t(), map() -> {:ok, term()} | {:error, Wardrik.Error.t()})

  @type t() :: %__MODULE__{
          operations: %{String.t() => {WardrikProtocol.operation(), JSV.Root.t()}},
          handlers: %{String.t() => handler()},
          streams: %{String.t() => handler()}
        }

  @operations Map.new(WardrikProtocol.operations(), &{&1.id, {&1, JSV.build!(&1.input)}})

  @doc "Returns the catalog of Wardrik's own operations."
  @spec new() :: t()
  def new do
    %__MODULE__{
      operations: @operations,
      handlers: %{
        "agents.list" => &Agents.list/2,
        "interrupts.list" => &Agents.interrupts/2,
        "events.list" => &Agents.events/2,
        "events.head" => &Agents.head/2,
        "agent.read" => &Agent.read/2,
        "agent.ask" => &Agent.ask/2,
        "agent.decide" => &Agent.decide/2,
        "agent.approve" => &Agent.approve/2,
        "agent.deny" => &Agent.deny/2,
        "agent.authorization" => &Agent.authorization/2,
        "agent.cancel" => &Agent.cancel/2,
        "agent.events" => &Agent.events/2,
        "agent.timeline" => &Agent.timeline/2,
        "agent.runs" => &Agent.runs/2,
        "agent.define" => &Lifecycle.define/2,
        "agent.definition" => &Lifecycle.definition/2,
        "agent.forget" => &Lifecycle.forget/2,
        "agent.spawn" => &Lifecycle.spawn/2,
        "agent.stop" => &Lifecycle.stop/2,
        "agent.clear" => &Lifecycle.clear/2,
        "agent.calls" => &Lifecycle.calls/2,
        "agent.kill" => &Lifecycle.kill/2,
        "agents.cancel" => &Agents.cancel/2,
        "agent.trigger_set" => &Triggers.set/2,
        "agent.trigger_remove" => &Triggers.remove/2,
        "hook.deliver" => &Triggers.deliver/2,
        "tokens.list" => &Tokens.list/2,
        "tokens.create" => &Tokens.create/2,
        "tokens.revoke" => &Tokens.revoke/2,
        "deployment.reload" => &Deployment.reload/2,
        "deployment.nodes" => &Deployment.nodes/2,
        "agent.move" => &Deployment.move/2,
        "connections.list" => &Owners.connections/2,
        "connections.connect" => &Owners.connect/2,
        "connections.disconnect" => &Owners.disconnect/2,
        "mcp_servers.list" => &Owners.servers/2,
        "mcp_servers.add" => &Owners.add/2,
        "mcp_servers.remove" => &Owners.remove/2,
        "hook.deliver_with_secret" => &Triggers.deliver/2,
        "channel.deliver" => &Channels.deliver/2,
        "agents.forget" => &Agents.forget/2,
        "audit.list" => &Deployment.audit/2
      },
      streams: %{
        "events.list" => &Agents.stream/2,
        "agent.events" => &Agent.stream/2
      }
    }
  end

  @doc "Returns the operation `id` names, with its input schema built, or `:error`."
  @spec fetch(t(), String.t()) :: {:ok, {WardrikProtocol.operation(), JSV.Root.t()}} | :error
  def fetch(%__MODULE__{operations: operations}, id), do: Map.fetch(operations, id)
end
