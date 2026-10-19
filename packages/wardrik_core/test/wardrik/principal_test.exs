defmodule Wardrik.PrincipalTest do
  use ExUnit.Case, async: true

  alias Wardrik.Principal

  test "names one known as a resource, with no wildcard" do
    for id <-
          ~w(acme acme/@jon deployment acme/agent/triage acme/@jon/agent/triage/thread/1696.1234
             acme/agent/x/trigger/hook) do
      assert Principal.id(Principal.new(id)) == id
    end
  end

  test "names anyone else as provider:subject, where they reached Wardrik" do
    for id <-
          ~w(slack:T0123/U024BE7LH shell:jon ssh:jon terminal:jon oauth:github globex-slack:T1/U2) do
      assert Principal.id(Principal.new(id, name: "jon")) == id
    end
  end

  test "refuses anything else" do
    for id <-
          [
            "",
            "acme/*",
            "acme/agent/tri?ge",
            "acme/front",
            "Slack:U1",
            "1slack:U1",
            "slack:",
            ":U1",
            "slack:U 1",
            "slack_x:U1",
            "deployment/@jon"
          ] do
      assert_raise ArgumentError, ~r/names no principal/, fn -> Principal.new(id) end
    end
  end

  test "carries the name they go by, and takes no other option" do
    assert Principal.name(Principal.new("acme/@jon", name: "Jon")) == "Jon"
    assert Principal.name(Principal.new("acme/@jon")) == nil
    assert_raise ArgumentError, fn -> Principal.new("acme/@jon", type: :user) end
  end

  test "deployment/0 is the deployment's own" do
    assert Principal.id(Principal.deployment()) == "deployment"
    assert Principal.same?(Principal.deployment(), Principal.new("deployment"))
  end

  test "same?/2 is the same name, whatever each goes by, and nobody is never anyone" do
    assert Principal.same?(Principal.new("shell:jon", name: "Jon"), Principal.new("shell:jon"))
    refute Principal.same?(Principal.new("shell:jon"), Principal.new("ssh:jon"))
    refute Principal.same?(nil, nil)
    refute Principal.same?(Principal.new("shell:jon"), nil)
  end
end
