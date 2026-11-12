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
    %{
      "agent" => id,
      "servers" => servers(Wardrik.mcp(wardrik), resolved.servers),
      "policy" => resolved.policy |> List.wrap() |> Enum.map(&Wardrik.Policy.to_json/1),
      "policies" =>
        Map.new(resolved.policies, fn {name, p} -> {name, Wardrik.Policy.to_json(p)} end),
      "defaults" => resolved.defaults,
      "notify" => Enum.map(Enum.sort(resolved.notify), &target/1),
      "channels" => resolved.channels,
      "workspaces" =>
        Map.new(resolved.workspaces, fn {agent, access} -> {agent, to_string(access)} end)
    }
    |> principal(resolved.principal)
  end

  defp servers(mcp, servers) do
    for {name, server} <- Enum.sort(servers) do
      picked = Wardrik.MCPTools.picked(mcp, servers, names: [name])
      tools = Wardrik.MCP.tools(nil, name: mcp, servers: picked)
      %{"name" => name, "server" => server, "tools" => Enum.map(tools, & &1.name)}
    end
  end

  defp target({name, key}) when is_binary(key), do: %{"name" => name, "target" => key}
  defp target({name, _given}), do: %{"name" => name}

  defp principal(view, nil), do: view
  defp principal(view, %{id: id}), do: Map.put(view, "principal", %{"id" => id})
end
