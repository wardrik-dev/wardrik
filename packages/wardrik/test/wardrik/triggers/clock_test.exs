defmodule Wardrik.Triggers.ClockTest do
  use ExUnit.Case, async: true

  alias Wardrik.Triggers.Clock

  defp next(every, timezone, from) do
    {:ok, clock} = Clock.parse(every)
    Clock.next(clock, timezone, from)
  end

  test "comes round on a cron expression, after the minute it's given" do
    assert next("0 9 * * *", "Etc/UTC", ~U[2026-10-22 08:59:59Z]) == ~U[2026-10-22 09:00:00Z]
    assert next("0 9 * * *", "Etc/UTC", ~U[2026-10-22 09:00:00Z]) == ~U[2026-10-23 09:00:00Z]
    assert next("*/15 * * * *", "Etc/UTC", ~U[2026-10-22 09:07:00Z]) == ~U[2026-10-22 09:15:00Z]
    assert next("@daily", "Etc/UTC", ~U[2026-10-22 09:07:00Z]) == ~U[2026-10-23 00:00:00Z]
  end

  test "reads a cron expression on a time zone's clock" do
    assert next("0 18 * * *", "Europe/Berlin", ~U[2026-07-01 09:00:00Z]) ==
             ~U[2026-07-01 16:00:00Z]

    assert next("0 18 * * *", "Europe/Berlin", ~U[2026-12-01 09:00:00Z]) ==
             ~U[2026-12-01 17:00:00Z]
  end

  test "runs a time the clocks skip at the first instant after the gap" do
    assert next("30 2 * * *", "Europe/Berlin", ~U[2026-03-28 12:00:00Z]) ==
             ~U[2026-03-29 01:00:00Z]
  end

  test "runs a time the clocks repeat on its first pass only" do
    first = next("30 2 * * *", "Europe/Berlin", ~U[2026-10-24 12:00:00Z])
    assert first == ~U[2026-10-25 00:30:00Z]
    assert next("30 2 * * *", "Europe/Berlin", first) == ~U[2026-10-26 01:30:00Z]
  end

  test "counts an interval from when it last ran" do
    assert next("30m", "Etc/UTC", ~U[2026-10-22 14:20:00Z]) == ~U[2026-10-22 14:50:00Z]
    assert next("1d", "Europe/Berlin", ~U[2026-10-22 14:20:00Z]) == ~U[2026-10-23 14:20:00Z]
  end

  test "says what it can't read" do
    assert {:error, "an interval is at least a minute"} = Clock.parse("30s")
    assert {:error, "@reboot isn't a time"} = Clock.parse("@reboot")
    assert {:error, "often is neither" <> _} = Clock.parse("often")
  end

  describe "at a single time" do
    defp at(at, timezone, from) do
      {:ok, clock} = Clock.parse_at(at)
      Clock.next(clock, timezone, from)
    end

    test "reads a time on a time zone's clock, or at its offset" do
      assert at("2026-11-17T09:00", "America/Los_Angeles", ~U[2026-11-12 00:00:00Z]) ==
               ~U[2026-11-17 17:00:00Z]

      assert at("2026-11-17T09:00:00+01:00", "Etc/UTC", ~U[2026-11-12 00:00:00Z]) ==
               ~U[2026-11-17 08:00:00Z]

      assert at("2026-11-17T17:00:00Z", "Etc/UTC", ~U[2026-11-12 00:00:00Z]) ==
               ~U[2026-11-17 17:00:00Z]
    end

    test "runs once, so a time that's past has no next run" do
      assert at("2026-11-17T09:00", "Etc/UTC", ~U[2026-11-17 09:00:00Z]) == nil
      assert at("2026-11-17T09:00", "Etc/UTC", ~U[2026-11-18 00:00:00Z]) == nil
    end

    test "runs a time the clocks skip just after the gap, and one they repeat on its first pass" do
      assert at("2026-03-29T02:30", "Europe/Berlin", ~U[2026-03-28 00:00:00Z]) ==
               ~U[2026-03-29 01:00:00Z]

      assert at("2026-10-25T02:30", "Europe/Berlin", ~U[2026-10-24 00:00:00Z]) ==
               ~U[2026-10-25 00:30:00Z]
    end

    test "says what it can't read" do
      assert {:error, "\"tuesday\" is not a time" <> _} = Clock.parse_at("tuesday")
      assert {:error, "7 is not a time" <> _} = Clock.parse_at(7)
    end
  end

  test "knows a time zone by its name" do
    assert Clock.zone?("Europe/Berlin")
    refute Clock.zone?("Mars/Olympus")
  end
end
