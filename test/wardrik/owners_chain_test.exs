defmodule Wardrik.Owners.ChainTest do
  use ExUnit.Case, async: true

  test "only Wardrik.Owners reads people out of an owner" do
    readers = for path <- Path.wildcard("lib/**/*.ex"), File.read!(path) =~ ~s("/@"), do: path

    assert readers == []
  end
end
