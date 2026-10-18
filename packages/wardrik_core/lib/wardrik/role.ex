defmodule Wardrik.Role do
  @moduledoc """
  A named set of actions, as `Wardrik.Statement` names them, which `bind/2`
  allows on the agents under a prefix:

      Wardrik.Role.bind([:reader, :messenger], Wardrik.AgentID.Prefix.new!(org: "acme"))

  | Role | Allows |
  | --- | --- |
  | `reader` | `agent.read`, `agent.events`, `agent.definition.read`, `agent.calls`, `agents.list`, `agents.parked`, `servers.list`, `connections.list` |
  | `messenger` | `agent.ask`, `agent.cancel`, `agents.cancel`, `agent.clear` |
  | `approver` | `agent.decide`, `agent.authorization.read` |
  | `definer` | `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget`, `agents.forget`, `agent.trigger.set`, `agent.trigger.remove`, `agent.call.kill`, `servers.add`, `servers.remove`, `connections.connect`, `connections.disconnect` |
  | `worker` | `agent.serve`, offering the agents tools |
  | `owner` | `*`, every action |

  Owning agents is holding `owner` over them. What acts on the deployment
  itself, its nodes, its tokens, its audit, reloading every agent and
  moving one, is checked against every agent's prefix, so only `owner` on
  every agent, root, may.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Statement

  @roles [
    reader: ~w(agent.read agent.events agent.definition.read agent.calls agents.list
               agents.parked servers.list connections.list),
    messenger: ~w(agent.ask agent.cancel agents.cancel agent.clear),
    approver: ~w(agent.decide agent.authorization.read),
    definer: ~w(agent.define agent.spawn agent.stop agent.forget agents.forget
                agent.trigger.set agent.trigger.remove agent.call.kill servers.add
                servers.remove connections.connect connections.disconnect),
    worker: ~w(agent.serve),
    owner: ~w(*)
  ]

  @type t() :: :reader | :messenger | :approver | :definer | :worker | :owner

  @doc "The actions `role` allows."
  @spec actions(t()) :: [Statement.action()]
  def actions(role), do: Keyword.fetch!(@roles, role)

  @doc "The statement allowing what each of `roles` does on the agents under `prefix`."
  @spec bind([t()], Prefix.t()) :: Statement.t()
  def bind(roles, prefix) when is_list(roles),
    do: %Statement{actions: Enum.uniq(Enum.flat_map(roles, &actions/1)), resources: [prefix]}

  @doc "The roles `names` name, or a message naming one that is none."
  @spec parse([String.t()]) :: {:ok, [t()]} | {:error, String.t()}
  def parse(names) when is_list(names) do
    named = Map.new(@roles, fn {role, _actions} -> {Atom.to_string(role), role} end)

    case Enum.reject(names, &Map.has_key?(named, &1)) do
      [] ->
        {:ok, Enum.map(names, &Map.fetch!(named, &1))}

      [unknown | _rest] ->
        {:error,
         "#{inspect(unknown)} is not a role; the roles are " <>
           Enum.map_join(Keyword.keys(@roles), ", ", &Atom.to_string/1)}
    end
  end
end
