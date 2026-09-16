defmodule TarsTUI.FleetTest do
  use ExUnit.Case, async: true

  alias Tars.Fleet.Member
  alias TarsTUI.Fleet
  alias TarsTUI.Text

  defp member(opts) do
    key = Keyword.get(opts, :key, "acme/jon/researcher")
    {org, user, name} = Tars.Fleet.parse(key)

    %Member{
      key: key,
      pid: self(),
      node: Keyword.get(opts, :node, node()),
      org: org,
      user: user,
      name: name,
      status: Keyword.get(opts, :status, :idle),
      pending: Keyword.get(opts, :pending, 0),
      waiting_on: Keyword.get(opts, :waiting_on, [])
    }
  end

  defp row(member, attached \\ "", width \\ 30), do: Fleet.row(member, attached, width)

  describe "heading/2" do
    test "says how many agents there are" do
      assert plain(Fleet.heading([member([]), member(key: "acme/jon/other")], 22)) =~ "fleet · 2"
    end
  end

  describe "row/3" do
    test "names the agent and what it is doing" do
      assert plain(row(member(key: "a/b/one"))) =~ "○ one"
      assert plain(row(member(key: "a/b/two", status: :running))) =~ "◐ two"

      assert plain(row(member(key: "a/b/three", status: :parked, waiting_on: ["deploy"]))) =~
               "? three deploy"
    end

    test "marks the agent this client is watching" do
      assert plain(row(member(key: "a/b/mine"), "a/b/mine")) =~ "› ○ mine"
      assert plain(row(member(key: "a/b/theirs"), "a/b/mine")) =~ "  ○ theirs"
    end

    test "counts what is queued behind an agent" do
      assert plain(row(member(pending: 3))) =~ "+3"
    end

    test "names the node an agent is on when it is not this one" do
      assert plain(row(member(node: :tars_b@somewhere))) =~ "@tars_b"
      refute plain(row(member([]))) =~ "@"
    end

    test "clips a row to the width it was given" do
      row = row(member(key: "a/b/an-extremely-long-agent-name-here"), "", 14)

      assert String.length(plain(row)) <= 14
    end
  end

  describe "width/1" do
    test "is never narrower than the minimum, even with nothing to show" do
      assert Fleet.width([]) == 22
      assert Fleet.width([member(key: "a/b/x")]) == 22
    end

    test "grows to fit the longest row and its node" do
      wide = member(key: "a/b/assistant_number_four", node: :tars_b@somewhere)

      assert Fleet.width([wide]) == String.length(plain(row(wide, "", 80))) + 5
    end

    test "stops at the maximum" do
      assert Fleet.width([member(key: "a/b/#{String.duplicate("x", 60)}")]) == 40
    end
  end

  describe "listing/1" do
    test "says so when nothing is running" do
      assert plain(Fleet.listing([])) =~ "no agents running"
    end

    test "gives each agent its full key, state and node" do
      assert [line] = Fleet.listing([member(status: :running)])

      assert plain(line) =~ "acme/jon/researcher"
      assert plain(line) =~ "running on #{node()}"
    end
  end

  defp plain(data) when is_binary(data), do: String.replace(data, ~r/\e\[[0-9;]*m/, "")
  defp plain(data), do: data |> Text.plain() |> plain()
end
