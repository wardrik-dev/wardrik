defmodule WardrikSchedule.StatusTest do
  use ExUnit.Case, async: true

  alias WardrikSchedule.Status

  test "described/1 says what each outcome did" do
    for {outcome, text} <- [
          {nil, "asking"},
          {:asked, "asked"},
          {:nothing_new, "found nothing new"},
          {:busy, "skipped, the agent was busy"},
          {:no_agent, "no agent runs under the key"},
          {:missed, "let a missed run go"},
          {:failed, "failed"}
        ] do
      assert Status.described(outcome) == text
    end
  end
end
