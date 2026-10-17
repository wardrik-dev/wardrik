defmodule WardrikChannel.InstallationTest do
  use ExUnit.Case, async: true

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias Wardrik.AgentID.Prefix
  alias WardrikChannel.Installation

  defp installed(owner),
    do: %Installation{channel: "slack", workspace: "T1", owner: owner, token: "xoxb-test"}

  test "an agent reads after the prefix it was installed for" do
    org = installed(Prefix.new!(org: "acme"))

    assert Installation.shown(org, ~A"acme/triage") == "triage"
    assert Installation.shown(org, ~A"acme/@jon/triage") == "@jon/triage"
    assert Installation.shown(org, ~A"acme/triage/C1-1.2") == "triage/C1-1.2"

    assert Installation.shown(
             installed(Prefix.new!(org: "acme", user: "jon")),
             ~A"acme/@jon/triage"
           ) ==
             "triage"
  end

  test "an agent outside the prefix, or under one that names everyone, reads whole" do
    assert Installation.shown(installed(Prefix.new!(org: "acme")), ~A"globex/triage") ==
             "globex/triage"

    assert Installation.shown(installed(Prefix.all()), ~A"acme/triage") == "acme/triage"
  end
end
