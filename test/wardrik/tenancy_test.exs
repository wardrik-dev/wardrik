defmodule Wardrik.TenancyTest do
  use ExUnit.Case, async: true

  @readers ~r{"/@"|"@" <>|Owners|AgentID\{owner|\.org\(|Definition\.principal|Wardrik\.Resource\b}

  test "no library module reads an owner or an org from an ID: your app's resolver says who" do
    readers = for path <- Path.wildcard("lib/**/*.ex"), File.read!(path) =~ @readers, do: path

    assert readers == []
  end
end
