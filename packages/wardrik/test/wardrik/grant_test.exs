defmodule Wardrik.GrantTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Grant
  alias Wardrik.Hook

  import Wardrik.AgentID, only: [sigil_A: 2]

  @acme Prefix.new!(org: "acme")

  defmodule Careful do
    @moduledoc false
    @behaviour Hook

    @impl true
    def init(opts), do: opts

    @impl true
    def call(call, _opts), do: call
  end

  test "a grant reaches the agents its scope covers" do
    {:ok, grant} = Grant.new(@acme)

    assert Grant.covers?(grant, ~A"acme/triage")
    refute Grant.covers?(grant, ~A"acme/@jon/triage")
    refute Grant.covers?(grant, ~A"globex/triage")
    refute Grant.covers?(grant, ~A"acmecorp/triage")

    {:ok, every} = Grant.new(Prefix.all())
    assert Grant.covers?(every, ~A"globex/triage")

    {:ok, one} = Grant.new(Prefix.of(~A"acme/@jon/triage"))
    assert Grant.covers?(one, ~A"acme/@jon/triage")
    assert Grant.covers?(one, ~A"acme/@jon/triage/t1")
    refute Grant.covers?(one, ~A"acme/@jon/triage2")
  end

  test "a grant holds its actions once each, in order, named or not" do
    assert {:ok, %Grant{can: [:read, :decide]}} =
             Grant.new(@acme, ["decide", :read, "decide"])

    assert {:ok, %Grant{can: can}} = Grant.new(@acme)
    assert can == Grant.actions()

    assert {:error, "A grant allows at least one action"} = Grant.new(@acme, [])

    assert {:error, message} = Grant.new(@acme, ["read", "write"])

    assert message ==
             ~s("write" is not an action; the actions are read, message, decide, define, serve)
  end

  test "allows?/3 wants the action and the reach both" do
    {:ok, grant} = Grant.new(@acme, [:read, :message])

    assert Grant.allows?(grant, :message, ~A"acme/triage")
    refute Grant.allows?(grant, :decide, ~A"acme/triage")
    refute Grant.allows?(grant, :message, ~A"acme/@jon/triage")
    refute Grant.allows?(grant, :message, ~A"globex/triage")
  end

  test "within/2 is what both grants let their holder do" do
    {:ok, org} = Grant.new(@acme, [:read, :message, :define])
    {:ok, one} = Grant.new(Prefix.of(~A"acme/triage"), [:read, :decide])

    assert {:ok, %Grant{scope: scope, can: [:read]}} = Grant.within(org, one)
    assert scope == Prefix.of(~A"acme/triage")
    assert Grant.within(one, org) == Grant.within(org, one)

    {:ok, globex} = Grant.new(Prefix.new!(org: "globex"))
    assert Grant.within(org, globex) == :error

    {:ok, decider} = Grant.new(@acme, [:decide])
    assert Grant.within(org, decider) == :error
  end

  describe "a ceiling" do
    test "is none unless given, and holds nothing back" do
      {:ok, grant} = Grant.new(@acme)

      assert grant.ceiling == []
      assert Grant.held(grant, [Hook.new("own", Careful)]) == [Hook.new("own", Careful)]
    end

    test "goes ahead of a definition's own hooks" do
      ceiling = [Hook.new("ceiling/careful", Careful)]
      {:ok, grant} = Grant.new(@acme, [:define], ceiling)

      assert grant.ceiling == ceiling

      assert Grant.held(grant, [Hook.new("own", Careful)]) ==
               ceiling ++ [Hook.new("own", Careful)]

      assert Grant.held(grant, nil) == ceiling
    end

    test "is only for a grant that can define, and is hooks" do
      ceiling = [Hook.new("ceiling/careful", Careful)]

      assert Grant.new(@acme, [:read], ceiling) ==
               {:error, "A ceiling holds the agents a grant defines, and this one cannot define"}

      assert Grant.new(@acme, [:define], [:careful]) ==
               {:error, "A ceiling is a list of Wardrik.Hook"}
    end
  end
end
