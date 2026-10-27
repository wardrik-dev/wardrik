defmodule Wardrik.Statement do
  @moduledoc """
  A statement allows some actions on the resources its patterns cover, as IAM's do. In a pattern,
  `*` stands for any run of characters, `/` too, and `?` for one.

      Wardrik.Statement.new(roles: [:reader, :messenger], resources: ["acme/agent/*"])
      Wardrik.Statement.new(actions: ["agent.*"], resources: ["acme/@jon/*"])

  A role is a named set of actions:

  | Role | Actions |
  | --- | --- |
  | `:reader` | `agent.read`, `agent.events`, `connection.read`, `mcp_server.read`, `ceiling.read` |
  | `:messenger` | `agent.ask`, `agent.cancel`, `agent.clear` |
  | `:approver` | `agent.decide` |
  | `:definer` | `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget`, `connection.connect`, `mcp_server.add` |
  | `:worker` | `agent.serve`, offering tools to the agents it covers |
  | `:owner` | every action |
  """

  @enforce_keys [:actions, :resources]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{actions: [String.t()], resources: [String.t()]}

  @roles %{
    reader: ["agent.read", "agent.events", "connection.read", "mcp_server.read", "ceiling.read"],
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
    worker: ["agent.serve"],
    owner: ["*"]
  }

  @doc "Returns the role a name writes, as `\"reader\"` for `:reader`, or `:error`."
  @spec role(String.t()) :: {:ok, atom()} | :error
  def role(name),
    do: Map.fetch(Map.new(@roles, fn {role, _actions} -> {Atom.to_string(role), role} end), name)

  @doc "Reads a statement from the protocol's JSON."
  @spec from_json(map()) :: t()
  def from_json(%{"actions" => actions, "resources" => resources}),
    do: %__MODULE__{actions: actions, resources: resources}

  @doc "Writes the statement as the protocol's JSON."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{actions: actions, resources: resources}),
    do: %{"actions" => actions, "resources" => resources}

  @doc "Builds a statement from `:actions` and `:roles`, on `:resources`."
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:resources, actions: [], roles: []])
    roles = Enum.flat_map(opts[:roles], &Map.fetch!(@roles, &1))

    %__MODULE__{actions: Enum.uniq(opts[:actions] ++ roles), resources: opts[:resources]}
  end
end
