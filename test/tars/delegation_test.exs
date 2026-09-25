defmodule Tars.DelegationTest do
  use ExUnit.Case, async: true

  alias Tars.Agent.Message
  alias Tars.Delegation
  alias Tars.Event
  alias Tars.Event.Source

  @agent "test/_/delegating"

  defp turn, do: Source.root(@agent, name: "turn")

  defp fold(events), do: Enum.reduce(events, Delegation.new(), &Delegation.fold(&2, &1))

  defp at(source, payload, ms) do
    %Event{source: source, payload: payload, at: ms * 1_000}
  end

  test "a delegation is known from where it started to how it ended" do
    turn = turn()
    pricing = Source.child(turn, name: "pricing")

    delegations =
      fold([
        at(turn, {:turn_started, [Message.new("go")]}, 0),
        at(pricing, {:span_started, "pricing"}, 10),
        at(pricing, {:delegation_started, "what do rivals charge?"}, 11)
      ])

    assert Delegation.summary(delegations) == %{active: 1, total: 1}

    assert [%{name: "pricing", task: "what do rivals charge?", status: :running} = record] =
             Delegation.list(delegations)

    assert Delegation.elapsed_ms(record, 1_011) == 1_000

    delegations =
      fold_more(delegations, [
        at(pricing, {:delegation_finished, {:ok, "about $20"}, 900}, 911),
        at(pricing, {:span_finished, :ok, 901}, 911)
      ])

    assert Delegation.summary(delegations) == %{active: 0, total: 1}
    assert [%{status: :ok, output: "about $20", duration_ms: 900}] = Delegation.list(delegations)
  end

  test "an unnamed delegation runs on the span it was given" do
    turn = turn()
    branch = Source.child(turn, name: "branch_0")

    delegations =
      fold([
        at(branch, {:span_started, "branch_0"}, 0),
        at(branch, {:delegation_started, "task"}, 1),
        at(branch, {:delegation_finished, {:error, :timeout}, 50}, 51)
      ])

    assert [%{span_id: id, name: "branch_0", status: :error, error: :timeout}] =
             Delegation.list(delegations)

    assert id == branch.trace.span_id
  end

  test "nested delegations count once each, and know their depth and their work" do
    turn = turn()
    research = Source.child(turn, name: "deep_research")
    tool = Source.child(research, name: "fan_out")
    angle = Source.child(tool, name: "pricing")
    search = Source.child(angle, name: "web_search")

    delegations =
      fold([
        at(research, {:span_started, "deep_research"}, 0),
        at(research, {:delegation_started, "research x"}, 1),
        at(tool, {:span_started, "fan_out"}, 2),
        at(angle, {:span_started, "pricing"}, 3),
        at(angle, {:delegation_started, "pricing angle"}, 4),
        at(search, {:span_started, "web_search"}, 5),
        at(search, {:span_finished, :ok, 40}, 45)
      ])

    assert Delegation.summary(delegations) == %{active: 2, total: 2}
    assert Delegation.depth(delegations, research.trace.span_id) == 0
    assert Delegation.depth(delegations, angle.trace.span_id) == 1

    assert [%{name: "web_search", status: :ok, duration_ms: 40}] =
             Delegation.activity(delegations, angle.trace.span_id)

    assert [%{name: "fan_out", status: :running}] =
             Delegation.activity(delegations, research.trace.span_id)
  end

  test "a branch killed by its fan-out is closed with its span" do
    turn = turn()
    branch = Source.child(turn, name: "slow")

    delegations =
      fold([
        at(branch, {:span_started, "slow"}, 0),
        at(branch, {:delegation_started, "task"}, 1),
        at(branch, {:span_finished, {:error, :timeout}, 5_000}, 5_001)
      ])

    assert [%{status: :error, error: :timeout, duration_ms: 5_000}] = Delegation.list(delegations)
  end

  test "a turn ending leaves nothing running, and the next turn starts over" do
    turn = turn()
    branch = Source.child(turn, name: "slow")

    delegations =
      fold([
        at(turn, {:turn_started, [Message.new("go")]}, 0),
        at(branch, {:span_started, "slow"}, 1),
        at(branch, {:delegation_started, "task"}, 2),
        at(turn, {:turn_interrupted, %{}}, 100)
      ])

    assert [%{status: :error, error: :interrupted, duration_ms: 98}] =
             Delegation.list(delegations)

    assert Delegation.summary(
             fold_more(delegations, [
               at(turn(), {:turn_started, [Message.new("again")]}, 200)
             ])
           ) ==
             %{active: 0, total: 0}
  end

  test "a failed ancestor closes nested delegations even if their tasks cannot emit an end" do
    branch = Source.child(turn(), name: "branch")
    delegate = Source.child(branch, name: "delegate")
    nested = Source.child(delegate, name: "nested")

    delegations =
      fold([
        at(branch, {:span_started, "branch"}, 0),
        at(delegate, {:delegation_started, "first"}, 1),
        at(nested, {:delegation_started, "nested"}, 2),
        at(branch, {:span_finished, {:error, :timeout}, 100}, 100)
      ])

    assert Delegation.summary(delegations) == %{active: 0, total: 2}
    assert Enum.all?(Delegation.list(delegations), &(&1.error == :timeout))
  end

  test "events that are not about delegations change nothing" do
    turn = turn()

    delegations = fold([at(turn, {:result, "text"}, 0), at(turn, {:model_started, "m0", "m"}, 1)])

    assert Delegation.list(delegations) == []
  end

  defp fold_more(delegations, events),
    do: Enum.reduce(events, delegations, &Delegation.fold(&2, &1))
end
