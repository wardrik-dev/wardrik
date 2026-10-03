defmodule WardrikTUI.FleetTest do
  use ExUnit.Case, async: true

  alias Wardrik.Fleet.Member
  alias WardrikTUI.Fleet
  alias WardrikTUI.Text

  defp member(opts) do
    key = Keyword.get(opts, :key, "acme/@jon/researcher")
    {org, user, name} = Wardrik.Fleet.parse(key)

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
  defp row(member, attached \\ "acme/@jon/mine", width \\ 30, opts \\ []),
    do: Fleet.row(member, attached, width, opts)

  describe "heading/5" do
    test "says how many agents there are, and how many are shown" do
      assert plain(Fleet.heading(2, 2, 0, "", 30)) == " fleet · 2"
      assert plain(Fleet.heading(1, 3, 0, "status:idle", 40)) == " fleet · 1/3 · status:idle"
    end

    test "counts the agents needing attention" do
      assert plain(Fleet.heading(3, 3, 2, "", 40)) == " fleet · 3 · 2 need attention"
    end
  end

  describe "attention?/2 and ambiguous/1" do
    test "a parked agent, or one with an unseen outcome, needs attention" do
      assert Fleet.attention?(member(status: :parked), %{})
      assert Fleet.attention?(member([]), %{"acme/@jon/researcher" => :ok})
      refute Fleet.attention?(member(status: :running), %{})
    end

    test "names shared by several agents are ambiguous" do
      members = [
        member(key: "acme/@jon/x"),
        member(key: "acme/@ann/x"),
        member(key: "acme/@jon/y")
      ]

      assert Fleet.ambiguous(members) == MapSet.new(["x"])
    end
  end

  describe "row/3" do
    test "names the agent and what it is doing" do
      assert plain(row(member(key: "acme/@jon/one"))) =~ "○ one"
      assert plain(row(member(key: "acme/@jon/two", status: :running))) =~ "◐ two"

      assert plain(row(member(key: "acme/@jon/three", status: :parked, waiting_on: ["deploy"]))) =~
               "? three deploy"
    end

    test "names an agent alone inside the attached agent's scope, and by key elsewhere" do
      assert plain(row(member(key: "acme/@jon/other"), "acme/@jon/mine")) =~ "○ other"
      refute plain(row(member(key: "acme/@jon/other"), "acme/@jon/mine")) =~ "acme"

      assert plain(row(member(key: "default/assistant"), "acme/@jon/assistant")) =~
               "○ default/assistant"

      assert plain(row(member(key: "acme/@ann/assistant"), "acme/@jon/assistant")) =~
               "○ acme/@ann/assistant"

      assert plain(row(member(key: "default/mine"), "default/mine")) =~ "› ○ mine"
    end

    test "shows the whole key when another agent shares the name" do
      shared = MapSet.new(["researcher"])

      assert plain(row(member([]), "acme/@jon/mine", 40, ambiguous: shared)) =~
               "○ acme/@jon/researcher"
    end

    test "marks an agent needing attention, and a result not yet seen" do
      assert plain(row(member(status: :parked, waiting_on: ["deploy"]))) =~
               "! ? researcher deploy"

      assert plain(row(member([]), "acme/@jon/mine", 40, unseen: :ok)) =~
               "! ○ researcher new result"

      assert plain(row(member(outcome: :failed), "acme/@jon/mine", 40, unseen: :failed)) =~
               "! ○ researcher failed"

      refute plain(row(member([]))) =~ "!"
    end

    test "marks the agent this client is watching" do
      assert plain(row(member(key: "a/@b/mine"), "a/@b/mine")) =~ "› ○ mine"
      assert plain(row(member(key: "a/@b/theirs"), "a/@b/mine")) =~ "  ○ theirs"
    end

    test "counts what is queued behind an agent" do
      assert plain(row(member(pending: 3))) =~ "+3"
    end

    test "counts the delegations of the current turn, and says when the last turn failed" do
      sub = fn member, active, total ->
        plain(row(member, "acme/@jon/mine", 30, delegations: %{active: active, total: total}))
      end

      assert sub.(member(status: :running), 2, 4) =~ "◐ researcher sub 2/4"
      assert sub.(member([]), 0, 3) =~ "○ researcher sub 0/3"
      refute plain(row(member([]))) =~ "sub"

      assert plain(row(member(outcome: :failed))) =~ "○ researcher failed"
      refute plain(row(member(status: :running, outcome: :failed))) =~ "failed"
    end

    test "names the node an agent is on when it is not this one" do
      assert plain(row(member(node: :wardrik_b@somewhere))) =~ "@wardrik_b"
      refute plain(row(member([]))) =~ "@"
    end

    test "clips a row to the width it was given" do
      row = row(member(key: "a/@b/an-extremely-long-agent-name-here"), "", 14)

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

  describe "listing/1" do
    test "says so when nothing is running" do
      assert plain(Fleet.listing([])) =~ "no agents running"
    end

    test "gives each agent its full key, state and node" do
      assert [line] = Fleet.listing([member(status: :running)])

      assert plain(line) =~ "acme/@jon/researcher"
      assert plain(line) =~ "running on #{node()}"
    end
  end

  defp plain(data) when is_binary(data), do: String.replace(data, ~r/\e\[[0-9;]*m/, "")
  defp plain(data), do: data |> Text.plain() |> plain()
end
