defmodule Wardrik.TimeZoneTest do
  use ExUnit.Case, async: true

  alias Wardrik.TimeZone

  setup do
    {:ok, berlin} = TimeZone.new("Europe/Berlin")
    %{berlin: berlin}
  end

  describe "new/1" do
    test "reads a zone the database knows" do
      assert {:ok, %TimeZone{name: "America/New_York"}} = TimeZone.new("America/New_York")
    end

    test "refuses a name it does not know, or one that is not a name" do
      assert {:error, ~s("Europe/Berln" is not a time zone)} = TimeZone.new("Europe/Berln")
      assert {:error, "a time zone is a name such as Europe/Berlin, got 1"} = TimeZone.new(1)
    end
  end

  test "utc/0 is Etc/UTC, and a zone is written as its name" do
    assert "Etc/UTC" = to_string(TimeZone.utc())
  end

  describe "local/2 and at/2" do
    test "convert between an instant and the zone's wall clock", %{berlin: berlin} do
      assert ~N[2026-07-01 18:00:00] = TimeZone.local(berlin, ~U[2026-07-01 16:00:00Z])
      assert ~U[2026-07-01 16:00:00Z] = TimeZone.at(berlin, ~N[2026-07-01 18:00:00])
      assert ~U[2026-01-15 17:00:00Z] = TimeZone.at(berlin, ~N[2026-01-15 18:00:00])
    end

    test "read a time the clocks skip as the first instant after the gap", %{berlin: berlin} do
      assert ~U[2026-03-29 01:00:00Z] = TimeZone.at(berlin, ~N[2026-03-29 02:30:00])
    end

    test "read a time the clocks repeat as its first pass", %{berlin: berlin} do
      assert ~U[2026-10-25 00:30:00Z] = TimeZone.at(berlin, ~N[2026-10-25 02:30:00])
    end
  end
end
