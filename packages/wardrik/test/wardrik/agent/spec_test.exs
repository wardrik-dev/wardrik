defmodule Wardrik.Agent.SpecTest do
  use ExUnit.Case, async: true

  alias Wardrik.Agent.Spec

  import Wardrik.AgentID, only: [sigil_A: 2]

  test "new/1 needs an ID, and gives a config when none is given" do
    spec = Spec.new(id: ~A"acme/triage")

    assert spec.id == ~A"acme/triage"
    assert spec.config == Wardrik.LLM.Config.new()
    assert_raise ArgumentError, fn -> Spec.new(description: "no ID") end
    assert_raise KeyError, fn -> Spec.new(id: ~A"acme/triage", nmae: "triage") end
  end

  test "options/1 is the config, the idle timeout and every seam the spec sets" do
    hooks = [%Wardrik.Hook{name: "some", module: SomeHook}]
    spec = Spec.new(id: ~A"acme/triage", hooks: hooks, timeout: 60_000)

    assert Spec.options(spec) == [
             config: spec.config,
             idle_timeout: :timer.minutes(15),
             hooks: hooks,
             timeout: 60_000
           ]

    assert [_config, idle_timeout: :infinity] =
             Spec.options(Spec.new(id: ~A"acme/triage", idle_timeout: :infinity))
  end
end
