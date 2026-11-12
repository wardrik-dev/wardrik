defmodule Wardrik.TenancyTest do
  use ExUnit.Case, async: true

  @libraries ~w(wardrik wardrik_core wardrik_protocol)a

  @readers ~r{"/@"|"@" <>|Owners|AgentID|\.org\(|Definition\.principal|Wardrik\.Resource\b}

  # Splitting, slicing or matching on what an agent ID holds.
  @parsers ~r{String\.(split|starts_with\?|replace_prefix|slice)\((agent|agent_id|id|log|source)\b|
              (agent|agent_id|id)\s*\|>\s*String\.(split|starts_with\?)|
              \b(agent|agent_id|id)\s*<>\s*"/"|
              "/agents/",\s*parts}x

  # Lines that split something else held in a variable of the same name.
  @others [
    # wardrik_protocol: an operation ID, as "agent.ask".
    ~s|defp parts(id), do: String.split(id, ".", parts: 2)|,
    # Wardrik.Policy: a tool name pattern, as "github/*".
    ~s|def glob(source), do: String.split(source, "*")|
  ]

  test "no library module reads an owner or an org from an ID: your app's resolver says who" do
    assert readers(@readers) == []
  end

  test "no library module splits or parses an agent ID: it's opaque" do
    refute Code.ensure_loaded?(Wardrik.AgentID)
    assert readers(@parsers) == []
  end

  test "the scan sees what it looks for" do
    for parser <- [
          ~s|String.split(agent, "/")|,
          ~s(id |> String.split\("/"\)),
          ~s|String.starts_with?(conversation, id <> "/")|,
          ~s|String.split(source, "/agents/", parts: 2)|
        ],
        do: assert(parser =~ @parsers, parser)
  end

  defp readers(pattern) do
    for app <- @libraries,
        path <- app |> source() |> Path.join("lib/**/*.ex") |> Path.wildcard(),
        path |> File.read!() |> String.split("\n") |> Enum.any?(&reads?(&1, pattern)),
        uniq: true,
        do: path
  end

  defp reads?(line, pattern), do: line =~ pattern and String.trim(line) not in @others

  defp source(:wardrik), do: File.cwd!()
  defp source(app), do: Map.fetch!(Mix.Project.deps_paths(), app)
end
