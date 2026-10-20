defmodule WardrikChannel.InstallationTest do
  use ExUnit.Case, async: true

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias Wardrik.Resource
  alias WardrikChannel.Installation

  defp installed(owner),
    do: %Installation{channel: "slack", workspace: "T1", owner: owner, token: "xoxb-test"}

  test "an agent reads after the prefix it was installed for" do
    org = installed(Resource.parse!("acme"))

    assert Installation.shown(org, ~A"acme/triage") == "triage"
    assert Installation.shown(org, ~A"acme/@jon/triage") == "@jon/triage"
    assert Installation.shown(org, Wardrik.Thread.parse!("acme/triage/C1-1.2")) == "triage/C1-1.2"

    assert Installation.shown(
             installed(Resource.parse!("acme/@jon")),
             ~A"acme/@jon/triage"
           ) ==
             "triage"
  end

  test "an agent outside the prefix, or under one that names everyone, reads whole" do
    assert Installation.shown(installed(Resource.parse!("acme")), ~A"globex/triage") ==
             "globex/triage"

    assert Installation.shown(installed(Resource.parse!("*")), ~A"acme/triage") == "acme/triage"
  end

  test "an owner covers its own agents, an org its users' too, and * every org's" do
    acme = installed(Resource.parse!("acme"))

    assert Installation.covers?(acme, ~A"acme/triage")
    assert Installation.covers?(acme, Wardrik.Thread.parse!("acme/@jon/triage/C1-1.2"))
    refute Installation.covers?(acme, ~A"globex/triage")
    refute Installation.covers?(acme, ~A"acme-labs/triage")

    assert Installation.covers?(installed(Resource.parse!("acme/@jon")), ~A"acme/@jon/triage")
    refute Installation.covers?(installed(Resource.parse!("acme/@jon")), ~A"acme/triage")
    assert Installation.covers?(installed(Resource.parse!("*")), ~A"globex/@ana/triage")
  end
end
