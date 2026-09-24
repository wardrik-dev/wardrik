defmodule Tars.Agent.SpecTest do
  use ExUnit.Case, async: true

  alias Tars.Agent.Spec

  test "new/1 needs a name, and gives a config when none is given" do
    spec = Spec.new(name: "triage")

    assert spec.config == Tars.LLM.Config.new()
    assert_raise ArgumentError, fn -> Spec.new(org: "acme") end
    assert_raise KeyError, fn -> Spec.new(name: "triage", nmae: "triage") end
  end

  test "key/1 is the fleet key of its name, org and user" do
    assert Spec.key(Spec.new(name: "triage", org: "acme", user: "jon")) == "acme/jon/triage"
    assert Spec.key(Spec.new(name: "triage")) == "_/_/triage"
  end

  test "new/1 refuses a name, org or user a key cannot hold" do
    assert_raise ArgumentError, ~r/may not contain "\/"/, fn -> Spec.new(name: "a/b") end

    assert_raise ArgumentError, ~r/may not contain "\/"/, fn ->
      Spec.new(name: "x", org: "acme/eu")
    end
  end

  test "options/1 is the config and every seam the spec sets" do
    spec = Spec.new(name: "triage", policy: SomePolicy, timeout: 60_000)

    assert Spec.options(spec) == [config: spec.config, policy: SomePolicy, timeout: 60_000]
  end
end
