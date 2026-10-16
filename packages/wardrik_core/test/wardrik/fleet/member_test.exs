defmodule Wardrik.Fleet.MemberTest do
  use ExUnit.Case, async: true

  alias Wardrik.Fleet.Member

  import Wardrik.AgentID, only: [sigil_A: 2]

  defp member(fields) do
    struct!(
      %Member{
        id: ~A"acme/triage",
        pid: nil,
        node: nil,
        status: :idle,
        pending: 0,
        waiting_on: []
      },
      fields
    )
  end

  test "says what an agent is doing, in the words every surface shows" do
    for {fields, state, label} <- [
          {[status: :parked, asleep: true], :parked, "parked, asleep"},
          {[status: :parked], :parked, "parked"},
          {[asleep: true], :asleep, "asleep"},
          {[asleep: true, outcome: :failed], :asleep, "asleep"},
          {[status: :running], :running, "running"},
          {[outcome: :failed], :failed, "idle, last failed"},
          {[], :idle, "idle"}
        ] do
      assert {Member.state(member(fields)), Member.label(member(fields))} == {state, label}
    end
  end
end
