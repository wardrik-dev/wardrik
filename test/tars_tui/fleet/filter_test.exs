defmodule TarsTUI.Fleet.FilterTest do
  use ExUnit.Case, async: true

  alias Tars.Fleet.Member
  alias TarsTUI.Fleet.Filter

  defp member(key, opts \\ []) do
    {org, user, name} = Tars.Fleet.parse(key)

    %Member{
      key: key,
      pid: self(),
      node: Keyword.get(opts, :node, :tars_a@here),
      org: org,
      user: user,
      name: name,
      status: Keyword.get(opts, :status, :idle),
      pending: 0,
      waiting_on: []
    }
  end

  defp parse!(query) do
    {:ok, filter} = Filter.parse(query)
    filter
  end

  defp matching(query, members, attention \\ []) do
    filter = parse!(query)

    members
    |> Enum.filter(&Filter.match?(filter, &1, &1.key in attention))
    |> Enum.map(& &1.name)
  end

  defp members do
    [
      member("acme/jon/researcher", status: :running),
      member("acme/ann/writer", node: :tars_b@there),
      member("_/_/assistant", status: :parked)
    ]
  end

  test "no filter lets everything through" do
    assert Filter.none?(Filter.none())
    assert matching("", members()) == ["researcher", "writer", "assistant"]
    refute Filter.none?(parse!("acme"))
  end

  test "plain text matches the key, ignoring case" do
    assert matching("ACME", members()) == ["researcher", "writer"]
    assert matching("write", members()) == ["writer"]
  end

  test "name, org, user and node narrow by their part" do
    assert matching("name:res", members()) == ["researcher"]
    assert matching("org:acme", members()) == ["researcher", "writer"]
    assert matching("user:ann", members()) == ["writer"]
    assert matching("user:_", members()) == ["assistant"]
    assert matching("node:tars_b", members()) == ["writer"]
  end

  test "status and attention narrow by what the agent is doing and needs" do
    assert matching("status:running", members()) == ["researcher"]
    assert matching("status:parked", members()) == ["assistant"]
    assert matching("attention", members(), ["acme/ann/writer"]) == ["writer"]
  end

  test "every word must match" do
    assert matching("org:acme status:idle", members()) == ["writer"]
    assert matching("org:acme status:parked", members()) == []
  end

  test "a word that is not a filter is refused by name" do
    assert Filter.parse("status:busy") == {:error, "status:busy"}
    assert Filter.parse("size:large") == {:error, "size:large"}
    assert Filter.parse("acme size:large") == {:error, "size:large"}
  end

  test "describes the query as typed, one space between words" do
    assert Filter.describe(parse!("  org:acme   status:idle ")) == "org:acme status:idle"
  end
end
