defmodule Tars.PolicyTest do
  use ExUnit.Case, async: true

  alias Tars.LLM.Config
  alias Tars.Policy
  alias Tars.Scope

  defmodule Allowing do
    @behaviour Tars.Policy
    @impl true
    def authorize(_call, _scope), do: :allow
  end

  defmodule Selective do
    @behaviour Tars.Policy
    @impl true
    def authorize(%{name: "deploy"}, _scope), do: {:ask, "This ships to production."}
    def authorize(%{name: "drop"}, _scope), do: {:deny, "Never."}
    def authorize(_call, _scope), do: :allow
  end

  defmodule Confused do
    @behaviour Tars.Policy
    @impl true
    def authorize(_call, _scope), do: :maybe
  end

  defmodule Broken do
    @behaviour Tars.Policy
    @impl true
    def authorize(_call, _scope), do: raise("policy is broken")
  end

  defp scope, do: Scope.root(Config.new(), :assistant)
  defp call(name), do: %{id: "call_1", name: name, arguments: %{}}

  test "no policy allows everything, so a deployment without one configures nothing" do
    assert Policy.authorize(nil, call("anything"), scope()) == :allow
  end

  test "passes a policy's own answers straight through" do
    assert Policy.authorize(Allowing, call("echo"), scope()) == :allow

    assert Policy.authorize(Selective, call("deploy"), scope()) ==
             {:ask, "This ships to production."}

    assert Policy.authorize(Selective, call("drop"), scope()) == {:deny, "Never."}
  end

  test "a policy that answers something else denies rather than being ignored" do
    assert {:deny, reason} = Policy.authorize(Confused, call("echo"), scope())
    assert reason =~ ":maybe"
  end

  test "a policy that raises denies, because governance must not fail open" do
    assert {:deny, reason} = Policy.authorize(Broken, call("echo"), scope())
    assert reason =~ "policy is broken"
  end
end
