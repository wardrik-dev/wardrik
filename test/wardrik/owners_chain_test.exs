defmodule Wardrik.Owners.ChainTest do
  use ExUnit.Case, async: true

  alias Wardrik.Owners

  doctest Wardrik.Owners

  test "parses the deployment, an org and a person, and nothing else" do
    assert Owners.parse("deployment") == {:ok, %{org: nil, person: nil}}
    assert Owners.parse("acme") == {:ok, %{org: "acme", person: nil}}
    assert Owners.parse("acme/@jon") == {:ok, %{org: "acme", person: "jon"}}

    for owner <- ["", "acme/jon", "acme/@", "/@jon", "acme/@jon/notes", "slack:T0123/U024BE7LH"],
        do: assert(Owners.parse(owner) == :error)
  end

  test "resolves settings from the nearest owner out to the deployment" do
    assert Owners.chain("acme/@jon") == ["acme/@jon", "acme", "deployment"]
    assert Owners.chain("acme") == ["acme", "deployment"]
    assert Owners.chain("deployment") == ["deployment"]
    assert Owners.chain("slack:T0123/U024BE7LH") == ["slack:T0123/U024BE7LH", "deployment"]
  end

  test "only Wardrik.Owners reads people out of an owner" do
    readers =
      for path <- Path.wildcard("lib/**/*.ex"),
          path != "lib/wardrik/owners.ex",
          File.read!(path) =~ ~s("/@"),
          do: path

    assert readers == []
  end
end
