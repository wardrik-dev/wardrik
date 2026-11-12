defmodule WardrikDaemon.CLI.ClockTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.CLI.Clock

  @now ~U[2026-10-27 12:50:00Z]

  test "says how long from now a time is" do
    assert Clock.from_now(nil, @now) == nil
    assert Clock.from_now("2026-10-27T12:40:00Z", @now) == "now"
    assert Clock.from_now("2026-10-27T13:35:00Z", @now) == "in 45m"
    assert Clock.from_now("2026-10-27T15:50:00Z", @now) == "in 3h"
    assert Clock.from_now("2026-10-27T16:00:00Z", @now) == "in 3h 10m"
    assert Clock.from_now("2026-10-29T16:00:00Z", @now) == "in 2d 3h"
  end

  test "says an amount in few characters" do
    assert Clock.amount(950) == "950"
    assert Clock.amount(12_345) == "12.3k"
    assert Clock.amount(1_234_567) == "1.2M"
  end
end
