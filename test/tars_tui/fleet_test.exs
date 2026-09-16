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
      waiting_on: Keyword.get(opts, :waiting_on, []),
      delegations: Keyword.get(opts, :delegations, %{active: 0, total: 0}),
      outcome: Keyword.get(opts, :outcome)
    }
  end

  defp delegation(opts) do
    %{
      span_id: "s1",
      parent_span_id: "root",
      name: Keyword.get(opts, :name, "pricing"),
      task: "look into pricing",
      status: Keyword.get(opts, :status, :running),
      output: nil,
      error: nil,
      started_at: 1_000,
      duration_ms: Keyword.get(opts, :duration_ms)
    }
  end

  # Attached, by default, to an agent in the same org and user as `member/1`
  # builds, so rows are named alone unless a test says otherwise.
  defp row(member, attached \\ "acme/jon/mine", width \\ 30),
    do: Fleet.row(member, attached, width)

  describe "heading/2" do
    test "says how many agents there are" do
      assert plain(Fleet.heading([member([]), member(key: "acme/jon/other")], 22)) =~ "fleet · 2"
    end
  end

  describe "row/3" do
    test "names the agent and what it is doing" do
      assert plain(row(member(key: "acme/jon/one"))) =~ "○ one"
      assert plain(row(member(key: "acme/jon/two", status: :running))) =~ "◐ two"

      assert plain(row(member(key: "acme/jon/three", status: :parked, waiting_on: ["deploy"]))) =~
               "? three deploy"
    end

    test "names an agent alone inside the attached agent's scope, and by key elsewhere" do
      assert plain(row(member(key: "acme/jon/other"), "acme/jon/mine")) =~ "○ other"
      refute plain(row(member(key: "acme/jon/other"), "acme/jon/mine")) =~ "acme"

      assert plain(row(member(key: "_/_/assistant"), "acme/jon/assistant")) =~ "○ _/_/assistant"

      assert plain(row(member(key: "acme/ann/assistant"), "acme/jon/assistant")) =~
               "○ acme/ann/assistant"

      assert plain(row(member(key: "_/_/mine"), "_/_/mine")) =~ "› ○ mine"
    end

    test "marks the agent this client is watching" do
      assert plain(row(member(key: "a/b/mine"), "a/b/mine")) =~ "› ○ mine"
      assert plain(row(member(key: "a/b/theirs"), "a/b/mine")) =~ "  ○ theirs"
    end

    test "counts what is queued behind an agent" do
      assert plain(row(member(pending: 3))) =~ "+3"
    end

    test "counts the delegations of the current turn, and says when the last turn failed" do
      assert plain(row(member(status: :running, delegations: %{active: 2, total: 4}))) =~
               "◐ researcher sub 2/4"

      assert plain(row(member(delegations: %{active: 0, total: 3}))) =~ "○ researcher sub 0/3"
      refute plain(row(member([]))) =~ "sub"

      assert plain(row(member(outcome: :failed))) =~ "○ researcher failed"
      refute plain(row(member(status: :running, outcome: :failed))) =~ "failed"
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

  describe "delegation_row/5" do
    test "draws a delegation as a branch of the tree, with how it is going" do
      assert plain(Fleet.delegation_row(delegation([]), 0, false, 3_500, 40)) ==
               "  ├ ◐ pricing 2.5s"

      assert plain(
               Fleet.delegation_row(delegation(status: :ok, duration_ms: 900), 0, true, 0, 40)
             ) ==
               "  └ ✓ pricing 900ms"

      assert plain(
               Fleet.delegation_row(
                 delegation(status: :error, duration_ms: 5_000),
                 1,
                 true,
                 0,
                 40
               )
             ) ==
               "    └ ✗ pricing 5.0s"
    end

    test "clips to the width it was given" do
      assert String.length(plain(Fleet.delegation_row(delegation([]), 0, true, 0, 10))) <= 10
    end
  end

  describe "width/1" do
    test "is never narrower than the minimum, even with nothing to show" do
      assert Fleet.width([]) == 22
      assert Fleet.width([member(key: "a/b/x")]) == 22
    end

    test "grows to fit the longest row and its node" do
      wide = member(key: "acme/jon/assistant_number_four", node: :tars_b@somewhere)

      assert Fleet.width([wide], "acme/jon/mine") ==
               String.length(plain(row(wide, "acme/jon/mine", 80))) + 5
    end

    test "counts the scope only for rows that show it" do
      other = member(key: "acme/jon/researcher-two")

      assert Fleet.width([other], "acme/jon/mine") ==
               String.length(plain(row(other, "acme/jon/mine", 80))) + 5

      assert Fleet.width([other], "_/_/mine") > Fleet.width([other], "acme/jon/mine")
    end

    test "makes room for the delegation rows it is given" do
      long = Fleet.delegation(delegation(name: "a-longer-name"), 2, true, 0)

      assert Fleet.width([member(key: "a/b/x")], "a/b/mine", [long]) ==
               String.length(plain(long)) + 5
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
