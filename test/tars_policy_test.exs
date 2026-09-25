defmodule TarsPolicyTest do
  use ExUnit.Case, async: true

  alias Tars.LLM.Config
  alias Tars.Scope

  @written %{
    "allow" => ["web_search", "linear/*"],
    "ask" => %{"github/create_*" => "This opens an issue on GitHub."},
    "deny" => ["run_lua"],
    "default" => "deny"
  }

  describe "decide/2" do
    setup do
      %{policy: TarsPolicy.decode!(@written)}
    end

    test "allows what it allows", %{policy: policy} do
      assert TarsPolicy.decide(policy, "web_search") == :allow
      assert TarsPolicy.decide(policy, "linear__list_issues") == :allow
    end

    test "asks in its own words", %{policy: policy} do
      assert TarsPolicy.decide(policy, "github__create_issue") ==
               {:ask, "This opens an issue on GitHub."}
    end

    test "refuses what it denies, and what nothing names under default: deny", %{policy: policy} do
      assert {:deny, "run_lua is not allowed for this agent."} =
               TarsPolicy.decide(policy, "run_lua")

      assert {:deny, _reason} = TarsPolicy.decide(policy, "deep_research")
    end

    test "the strictest rule that names a call decides it" do
      policy =
        TarsPolicy.decode!(%{
          "allow" => ["*"],
          "ask" => ["github/*"],
          "deny" => ["github/delete_*"]
        })

      assert TarsPolicy.decide(policy, "web_search") == :allow

      assert {:ask, "github/create_issue needs your approval."} =
               TarsPolicy.decide(policy, "github__create_issue")

      assert {:deny, _reason} = TarsPolicy.decide(policy, "github__delete_repo")
    end

    test "a rule written with the name the agent knows a tool by decides it" do
      policy = TarsPolicy.decode!(%{"deny" => ["github__delete_repo"]})

      assert {:deny, "github/delete_repo is not allowed for this agent."} =
               TarsPolicy.decide(policy, "github__delete_repo")
    end

    test "allows what nothing names by default" do
      assert TarsPolicy.decide(TarsPolicy.decode!(%{}), "anything") == :allow
    end
  end

  describe "as a Tars.Hook" do
    test "decides tool calls through the seam, and allows every model call" do
      policy = TarsPolicy.decode!(%{"deny" => ["run_lua"], "ask" => ["deploy"]})
      scope = Scope.root(Config.new(), "acme/_/triage", hooks: TarsPolicy.hooks(policy))
      check = &(&1 |> Tars.Call.tool(scope) |> Tars.Hook.check())
      tool = &%{id: "c1", name: &1, arguments: %{}}

      assert %Tars.Call{state: :denied, denied: %{by: "policy"}} = check.(tool.("run_lua"))
      assert %Tars.Call{state: :waiting, asks: [%{by: "policy"}]} = check.(tool.("deploy"))
      assert %Tars.Call{state: :allowed} = check.(tool.("web_search"))

      model = Tars.Call.model(Tars.LLM.Request.new(Config.new(), ReqLLM.Context.new()), scope)
      assert %Tars.Call{state: :allowed} = Tars.Hook.check(model)
    end

    test "reads a policy written as data, as its init/1" do
      assert %TarsPolicy{} = TarsPolicy.init(%{"deny" => ["run_lua"]})
      assert_raise ArgumentError, fn -> TarsPolicy.init(%{"allows" => []}) end
    end

    test "is plain data, so it survives being written down" do
      policy = TarsPolicy.decode!(@written, "careful")
      assert policy |> :erlang.term_to_binary() |> :erlang.binary_to_term() == policy
    end
  end

  describe "decode/2 and encode/1" do
    test "round-trip" do
      policy = TarsPolicy.decode!(@written, "careful")

      assert policy.name == "careful"
      assert TarsPolicy.encode(policy) == @written
    end

    test "refuse a key they do not know" do
      assert {:error, "allows is not a setting" <> _rest} = TarsPolicy.decode(%{"allows" => []})
    end

    test "refuse a default that is not an effect" do
      assert {:error, "default is allow, ask or deny"} =
               TarsPolicy.decode(%{"default" => "maybe"})
    end

    test "refuse a budget that sets nothing" do
      assert {:error, "budget is a set of settings" <> _rest} =
               TarsPolicy.decode(%{"budget" => nil})

      assert {:ok, %TarsPolicy{budget: nil}} = TarsPolicy.decode(%{"default" => "allow"})
    end

    test "refuse rules that are not patterns" do
      assert {:error, "deny is a list" <> _rest} = TarsPolicy.decode(%{"deny" => "run_lua"})
      assert {:error, "allow names" <> _rest} = TarsPolicy.decode(%{"allow" => [7]})

      assert {:error, "ask gives x a message" <> _rest} =
               TarsPolicy.decode(%{"ask" => %{"x" => 1}})
    end
  end
end
