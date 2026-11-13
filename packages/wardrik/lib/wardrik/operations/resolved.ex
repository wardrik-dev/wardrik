defmodule Wardrik.Operations.Resolved do
  @moduledoc false

  # Shows what the app's resolver gives an agent, as Wardrik reads it. Notify targets the app
  # delivers itself are listed by name alone: their options can hold secrets.

  alias Wardrik.Operations.Snapshot
  alias Wardrik.Resolved
  alias Wardrik.Resolver

  @doc "Returns what the app gives the agent."
  @spec agent(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Wardrik.Error.t()}
  def agent(%Wardrik.Scope{wardrik: wardrik}, %{"agent" => id}) do
    with :ok <- Snapshot.known(wardrik, {id, nil}),
         {:ok, resolved} <- Resolver.defined(wardrik, id) do
      {:ok, view(wardrik, id, resolved)}
    end
  end

  defp view(wardrik, id, %Resolved{} = resolved) do
    policy = List.wrap(resolved.policy)
    notify = Enum.sort(resolved.notify)

    view = %{
      "agent" => id,
      "servers" => servers(Wardrik.mcp(wardrik), resolved.servers),
      "policy" => Enum.map(policy, &Wardrik.Policy.to_json/1),
      "policies" =>
        Map.new(resolved.policies, fn {name, p} -> {name, Wardrik.Policy.to_json(p)} end),
      "defaults" => resolved.defaults,
      "notify" => Enum.map(notify, &target/1),
      "channels" => resolved.channels,
      "workspaces" =>
        Map.new(resolved.workspaces, fn {agent, access} -> {agent, to_string(access)} end)
    }

    principal(view, resolved.principal)
  end

  defp servers(mcp, servers) do
    started = Wardrik.MCP.Servers.all(mcp)

    for {name, key} <- Enum.sort(servers) do
      picked = Wardrik.MCP.Capability.picked(mcp, servers, names: [name])
      tools = Wardrik.MCP.tools(nil, name: mcp, servers: picked)
      Map.merge(%{"name" => name, "tools" => Enum.map(tools, & &1.name)}, kept(started[key], key))
    end
  end

  defp kept(%Wardrik.MCP.Server{owner: owner} = server, _key) when owner != nil,
    do: %{"server" => Wardrik.MCP.Server.prefix(server), "owner" => owner}

  defp kept(_server, key), do: %{"server" => key}

  defp target({name, key}) when is_binary(key), do: %{"name" => name, "target" => key}
  defp target({name, _given}), do: %{"name" => name}

  defp principal(view, nil), do: view
  defp principal(view, %{id: id}), do: Map.put(view, "principal", %{"id" => id})
end
