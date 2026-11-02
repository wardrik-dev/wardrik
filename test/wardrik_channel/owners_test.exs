defmodule WardrikChannel.OwnersTest do
  use ExUnit.Case, async: true

  test "no module reads an owner or an org from an ID: your app's identities and authorizer do" do
    assert reading(~r{"/@"|String\.split\(owner|Owners|AgentID\{owner|\.org\(}) == []
  end

  test "no module reads anything out of an agent's ID, or follows logs by a pattern" do
    assert reading(~r{AgentID|"/agents/"|\.source\b|"\*/|logs\(}) == []
  end

  defp reading(pattern),
    do: for(path <- Path.wildcard("lib/**/*.ex"), File.read!(path) =~ pattern, do: path)
end
