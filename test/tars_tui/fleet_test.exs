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

  defp rows(members, attached \\ "", width \\ 22, height \\ 6) do
    members |> Fleet.panel(attached, width, height) |> String.split("\n")
  end

  describe "panel/4" do
    test "heads the panel with how many agents there are" do
      assert [heading | _rest] = rows([member([]), member(key: "acme/jon/other")])
      assert plain(heading) =~ "fleet · 2"
    end

    test "names each agent and what it is doing" do
      [_heading, idle, running, parked] =
        Enum.take(
          rows([
            member(key: "a/b/one"),
            member(key: "a/b/two", status: :running),
            member(key: "a/b/three", status: :parked, waiting_on: ["deploy"])
          ]),
          4
        )

      assert plain(idle) =~ "○ one"
      assert plain(running) =~ "◐ two"
      assert plain(parked) =~ "? three deploy"
    end

    test "marks the agent this client is watching" do
      [_heading, mine, theirs] =
        Enum.take(rows([member(key: "a/b/mine"), member(key: "a/b/theirs")], "a/b/mine"), 3)

      assert plain(mine) =~ "› ○ mine"
      assert plain(theirs) =~ "  ○ theirs"
    end

    test "counts what is queued behind an agent" do
      assert rows([member(pending: 3)]) |> Enum.at(1) |> plain() =~ "+3"
    end

    test "names the node an agent is on when it is not this one" do
      assert rows([member(node: :tars_b@somewhere)]) |> Enum.at(1) |> plain() =~ "@tars_b"
    end

    test "says nothing about the node an agent is on when it is this one" do
      refute rows([member([])]) |> Enum.at(1) |> plain() =~ "@"
    end

    test "fills the height it was given, however many agents there are" do
      assert Enum.count_until(rows([member([])], "", 22, 6), 20) == 6
      assert Enum.count_until(rows([], "", 22, 3), 20) == 3
    end

    test "clips a row to the width it was given" do
      row = rows([member(key: "a/b/an-extremely-long-agent-name-here")], "", 14) |> Enum.at(1)

      assert String.length(plain(row)) <= 14
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
