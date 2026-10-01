defmodule Wardrik.GrantTest do
  use ExUnit.Case, async: true

  alias Wardrik.Grant
  alias Wardrik.Hook

  defmodule Careful do
    @moduledoc false
    @behaviour Hook

    @impl true
    def init(opts), do: opts

    @impl true
    def call(call, _opts), do: call
  end

  test "a grant reaches the agents under its scope, and an empty scope reaches every agent" do
    {:ok, grant} = Grant.new("acme/")

    assert Grant.covers?(grant, "acme/@jon/triage")
    refute Grant.covers?(grant, "globex/triage")
    assert Grant.covers?(%{grant | scope: ""}, "globex/triage")
  end

  test "a scope ends at a segment, however it was written" do
    {:ok, grant} = Grant.new("acme/")
    refute Grant.covers?(grant, "acmecorp/triage")

    {:ok, one} = Grant.new("acme/@jon/triage")
    assert Grant.covers?(one, "acme/@jon/triage")
    refute Grant.covers?(one, "acme/@jon/triage2")

    # A scope held without its trailing slash is still read as a prefix.
    bare = %{grant | scope: "acme"}
    assert Grant.covers?(bare, "acme/@jon/triage")
    refute Grant.covers?(bare, "acmecorp/triage")
  end

  test "new/2 writes a scope as the key prefix it is" do
    for {given, scope} <- [
          {"", ""},
          {"acme", "acme/"},
          {"acme/", "acme/"},
          {"acme/@jon", "acme/@jon/"},
          {"acme/@jon/", "acme/@jon/"},
          {"acme/triage", "acme/triage"},
          {"acme/@jon/triage", "acme/@jon/triage"},
          {"acme/@jon/triage/", "acme/@jon/triage"}
        ] do
      assert {:ok, %Grant{scope: ^scope}} = Grant.new(given)
    end
  end

  test "new/2 refuses a scope that is not a key prefix" do
    for scope <- ["/", "/acme", "acme//jon", "acme/jon/triage", "acme/@jon/triage/more", "@jon/"] do
      assert {:error, message} = Grant.new(scope)
      assert message == "#{inspect(scope)} is not a scope; a scope is org/, org/@user/ or a key"
    end
  end

  test "a grant holds its actions once each, in order, named or not" do
    assert {:ok, %Grant{can: [:read, :decide]}} =
             Grant.new("acme/", ["decide", :read, "decide"])

    assert {:ok, %Grant{can: can}} = Grant.new("acme/")
    assert can == Grant.actions()

    assert {:error, "A grant allows at least one action"} = Grant.new("acme/", [])

    assert {:error, message} = Grant.new("acme/", ["read", "write"])

    assert message ==
             ~s("write" is not an action; the actions are read, message, decide, define, serve)
  end

  test "allows?/3 wants the action and the reach both" do
    {:ok, grant} = Grant.new("acme/", [:read, :message])

    assert Grant.allows?(grant, :message, "acme/@jon/triage")
    refute Grant.allows?(grant, :decide, "acme/@jon/triage")
    refute Grant.allows?(grant, :message, "globex/@jon/triage")
  end

  describe "a ceiling" do
    test "is none unless given, and holds nothing back" do
      {:ok, grant} = Grant.new("acme/")

      assert grant.ceiling == []
      assert Grant.held(grant, [Hook.new("own", Careful)]) == [Hook.new("own", Careful)]
    end

    test "goes ahead of a definition's own hooks" do
      ceiling = [Hook.new("ceiling/careful", Careful)]
      {:ok, grant} = Grant.new("acme/", [:define], ceiling)

      assert grant.ceiling == ceiling

      assert Grant.held(grant, [Hook.new("own", Careful)]) ==
               ceiling ++ [Hook.new("own", Careful)]

      assert Grant.held(grant, nil) == ceiling
    end

    test "is only for a grant that can define, and is hooks" do
      ceiling = [Hook.new("ceiling/careful", Careful)]

      assert Grant.new("acme/", [:read], ceiling) ==
               {:error, "A ceiling holds the agents a grant defines, and this one cannot define"}

      assert Grant.new("acme/", [:define], [:careful]) ==
               {:error, "A ceiling is a list of Wardrik.Hook"}
    end
  end
end
