defmodule WardrikHTTP.RoutesTest do
  use ExUnit.Case, async: true

  alias WardrikHTTP.Routes

  test "routes every operation by its method and path, and its conversation route" do
    for operation <- WardrikProtocol.operations(),
        path <- [operation.path, operation.conversation],
        path != nil,
        agent <- ["agt_01JF8X5RQ2", "acme/@jon/triage", "a b%2F"] do
      {segments, params} = filled(path, agent)
      method = String.upcase(operation.method)

      assert {:ok, %{id: id}, ^params} = Routes.match(method, segments)

      assert id == operation.id,
             "#{method} #{inspect(segments)} routed to #{id}, not #{operation.id}"
    end
  end

  test "takes the conversation as a field of its own" do
    assert {:ok, %{id: "agent.ask"}, %{"agent" => "agt_1", "conversation" => "C1/1696.1234"}} =
             Routes.match("POST", [
               "v1",
               "agents",
               "agt_1",
               "conversations",
               "C1/1696.1234",
               "messages"
             ])

    assert {:ok, %{id: "agent.clear"}, %{"agent" => "agt_1", "conversation" => "C1"}} =
             Routes.match("DELETE", ~w(v1 agents agt_1 conversations C1))
  end

  test "finds no route for a path no operation has" do
    assert Routes.match("GET", ["v1", "nothing"]) == :error
    assert Routes.match("PATCH", ["v1", "agents"]) == :error
    assert Routes.match("POST", ~w(v1 agents acme triage messages)) == :error
    assert Routes.match("POST", ~w(v1 agents agt_1 conversations messages)) == :error
    assert Routes.match("PUT", ~w(v1 agents agt_1 conversations C1)) == :error
  end

  # Path segments arrive decoded: each parameter is one segment, whatever it holds.
  defp filled(template, agent) do
    template
    |> String.split("/", trim: true)
    |> Enum.map_reduce(%{}, fn
      "{agent}", params -> {agent, Map.put(params, "agent", agent)}
      "{" <> name, params -> param(String.trim_trailing(name, "}"), params)
      literal, params -> {literal, params}
    end)
  end

  defp param(name, params), do: {"x" <> name, Map.put(params, name, "x" <> name)}
end
