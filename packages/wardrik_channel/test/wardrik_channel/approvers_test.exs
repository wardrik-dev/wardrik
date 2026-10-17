defmodule WardrikChannel.ApproversTest do
  use ExUnit.Case, async: true

  alias WardrikChannel.Approvers
  alias WardrikChannel.Approvers.Anyone
  alias WardrikChannel.Approvers.Named

  defp among(user), do: &(user in &1)

  test "the people named decide, and are each asked directly" do
    named = %Named{names: ["@maria", "U2"]}

    assert Approvers.decides?(named, among("U2"))
    refute Approvers.decides?(named, among("U9"))
    assert Approvers.asked(named) == ["@maria", "U2"]
    assert Approvers.described(named) == "@maria, U2 decide"
    assert Approvers.described(%Named{names: ["@maria"]}) == "@maria decides"
  end

  test "naming nobody, nobody named decides, and nobody is asked" do
    nobody = %Named{names: []}

    refute Approvers.decides?(nobody, among("U1"))
    assert Approvers.asked(nobody) == []
    assert Approvers.described(nobody) =~ "names no approvers"
  end

  test "anyone in the channel decides, and nobody is asked directly" do
    assert Approvers.decides?(%Anyone{}, among("U9"))
    assert Approvers.asked(%Anyone{}) == []
    assert Approvers.described(%Anyone{}) == "anyone in it decides"
  end
end
