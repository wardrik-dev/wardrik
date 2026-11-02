defmodule WardrikChannel.OwnersTest do
  use ExUnit.Case, async: true

  test "no module reads an owner or an org from an ID: your app's identities and authorizer do" do
    readers =
      for path <- Path.wildcard("lib/**/*.ex"),
          File.read!(path) =~ ~r{"/@"|String\.split\(owner|Owners|AgentID\{owner|\.org\(},
          do: path

    assert readers == []
  end
end
