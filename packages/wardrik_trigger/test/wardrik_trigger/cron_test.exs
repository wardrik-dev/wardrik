defmodule WardrikTrigger.CronTest do
  use ExUnit.Case, async: true

  alias WardrikTrigger.Cron

  defp next(text, from) do
    {:ok, cron} = Cron.parse(text)
    {:ok, at} = Cron.next(cron, from)
    at
  end

  describe "next/2" do
    test "steps through the minutes a step names" do
      assert next("*/30 * * * *", ~U[2026-09-24 09:10:00Z]) == ~U[2026-09-24 09:30:00Z]
      assert next("*/30 * * * *", ~U[2026-09-24 09:30:00Z]) == ~U[2026-09-24 10:00:00Z]
    end

    test "names the first minute strictly after the one given, whatever its seconds" do
      assert next("* * * * *", ~U[2026-09-24 09:10:59.999Z]) == ~U[2026-09-24 09:11:00Z]
    end

    test "skips to the next weekday a range allows" do
      # 2026-09-25 is a Friday.
      assert next("0 9 * * 1-5", ~U[2026-09-25 10:00:00Z]) == ~U[2026-09-28 09:00:00Z]
    end

    test "reads 7 as Sunday, as 0 is" do
      assert next("0 0 * * 7", ~U[2026-09-24 00:00:00Z]) == ~U[2026-09-27 00:00:00Z]
      assert next("0 0 * * 0", ~U[2026-09-24 00:00:00Z]) == ~U[2026-09-27 00:00:00Z]
    end

    test "matches either day when both the day of the month and of the week are restricted" do
      assert next("0 0 1 * 1", ~U[2026-09-24 00:00:00Z]) == ~U[2026-09-28 00:00:00Z]
      assert next("0 0 1 * 1", ~U[2026-09-28 00:00:00Z]) == ~U[2026-10-01 00:00:00Z]
    end

    test "runs a start with a step to the end of its field" do
      assert next("5/15 * * * *", ~U[2026-09-24 09:36:00Z]) == ~U[2026-09-24 09:50:00Z]
      assert next("5/15 * * * *", ~U[2026-09-24 09:50:00Z]) == ~U[2026-09-24 10:05:00Z]
    end

    test "reads lists and ranges with steps" do
      assert next("0 8,12-18/3 * * *", ~U[2026-09-24 08:00:00Z]) == ~U[2026-09-24 12:00:00Z]
      assert next("0 8,12-18/3 * * *", ~U[2026-09-24 15:00:00Z]) == ~U[2026-09-24 18:00:00Z]
    end

    test "crosses the years to a 29th of February" do
      assert next("0 0 29 2 *", ~U[2026-03-01 00:00:00Z]) == ~U[2028-02-29 00:00:00Z]
    end

    test "reads the named expressions" do
      assert next("@daily", ~U[2026-09-24 09:10:00Z]) == ~U[2026-09-25 00:00:00Z]
      assert next("@hourly", ~U[2026-09-24 09:10:00Z]) == ~U[2026-09-24 10:00:00Z]
    end
  end

  describe "parse/1" do
    test "keeps the text it read" do
      assert {:ok, %Cron{source: "*/30 * * * *"}} = Cron.parse("  */30 * * * *  ")
    end

    test "refuses what is not five fields" do
      assert {:error, message} = Cron.parse("* * * *")
      assert message =~ "not five fields"
    end

    test "refuses a value out of its field's range" do
      assert {:error, "minutes: " <> message} = Cron.parse("60 * * * *")
      assert message =~ "from 0 to 59"
    end

    test "refuses a step of zero and a range that runs backwards" do
      assert {:error, message} = Cron.parse("*/0 * * * *")
      assert message =~ "positive number"

      assert {:error, message} = Cron.parse("5-1 * * * *")
      assert message =~ "runs backwards"
    end

    test "refuses an expression naming no day that exists" do
      assert {:error, message} = Cron.parse("0 0 31 2 *")
      assert message =~ "names no time that exists"
    end
  end
end
