defmodule Wardrik.Statement do
  @moduledoc """
  A statement allows some actions on the resources its patterns cover, as IAM's do. In a pattern,
  `*` stands for any run of characters, `/` too, and `?` for one.

      Wardrik.Statement.new(roles: [:reader, :messenger], resources: ["acme/agent/*"])
      Wardrik.Statement.new(actions: ["agent.*"], resources: ["acme/@jon/*"])

  A role is a named set of actions:

  | Role | Actions |
  | --- | --- |
  | `:reader` | `agent.read`, `agent.events`, `connection.read`, `mcp_server.read` |
  | `:messenger` | `agent.ask`, `agent.cancel`, `agent.clear` |
  | `:approver` | `agent.decide` |
  | `:definer` | `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget`, `connection.connect`, `mcp_server.add` |
  | `:owner` | every action |
  """

  @enforce_keys [:actions, :resources]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{actions: [String.t()], resources: [String.t()]}

  @roles %{
    reader: ["agent.read", "agent.events", "connection.read", "mcp_server.read"],
    messenger: ["agent.ask", "agent.cancel", "agent.clear"],
    approver: ["agent.decide"],
    definer: [
      "agent.define",
      "agent.spawn",
      "agent.stop",
      "agent.forget",
      "connection.connect",
      "mcp_server.add"
    ],
    owner: ["*"]
  }

  @doc "Builds a statement from `:actions` and `:roles`, on `:resources`."
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:resources, actions: [], roles: []])
    roles = Enum.flat_map(opts[:roles], &Map.fetch!(@roles, &1))

    %__MODULE__{actions: Enum.uniq(opts[:actions] ++ roles), resources: opts[:resources]}
  end
end
