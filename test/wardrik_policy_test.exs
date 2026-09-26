defmodule WardrikPolicyTest do
  use ExUnit.Case, async: true

  alias Wardrik.LLM.Config
  alias Wardrik.Scope

  @written %{
    "allow" => ["web_search", "linear/*"],
    "ask" => %{"github/create_*" => "This opens an issue on GitHub."},
    "deny" => ["run_lua"],
    "default" => "deny"
  }

  describe "decide/2" do
    setup do
      %{policy: WardrikPolicy.decode!(@written)}
    end

    test "allows what it allows", %{policy: policy} do
      assert WardrikPolicy.decide(policy, "web_search") == :allow
      assert WardrikPolicy.decide(policy, "linear__list_issues") == :allow
    end

    test "asks in its own words", %{policy: policy} do
      assert WardrikPolicy.decide(policy, "github__create_issue") ==
               {:ask, "This opens an issue on GitHub."}
    end

    test "refuses what it denies, and what nothing names under default: deny", %{policy: policy} do
      assert {:deny, "run_lua is not allowed for this agent."} =
               WardrikPolicy.decide(policy, "run_lua")

      assert {:deny, _reason} = WardrikPolicy.decide(policy, "deep_research")
    end

    test "the strictest rule that names a call decides it" do
      policy =
        WardrikPolicy.decode!(%{
          "allow" => ["*"],
          "ask" => ["github/*"],
          "deny" => ["github/delete_*"]
        })

      assert WardrikPolicy.decide(policy, "web_search") == :allow

      assert {:ask, "github/create_issue needs your approval."} =
               WardrikPolicy.decide(policy, "github__create_issue")

      assert {:deny, _reason} = WardrikPolicy.decide(policy, "github__delete_repo")
    end

    test "a rule written with the name the agent knows a tool by decides it" do
      policy = WardrikPolicy.decode!(%{"deny" => ["github__delete_repo"]})

      assert {:deny, "github/delete_repo is not allowed for this agent."} =
               WardrikPolicy.decide(policy, "github__delete_repo")
    end

    test "allows what nothing names by default" do
      assert WardrikPolicy.decide(WardrikPolicy.decode!(%{}), "anything") == :allow
    end
  end

  describe "as a Wardrik.Hook" do
    test "decides tool calls through the seam, and allows every model call" do
      policy = WardrikPolicy.decode!(%{"deny" => ["run_lua"], "ask" => ["deploy"]})
      scope = Scope.root(Config.new(), "acme/_/triage", hooks: WardrikPolicy.hooks(policy))
      check = &(&1 |> Wardrik.Call.tool(scope) |> Wardrik.Hook.check())
      tool = &%{id: "c1", name: &1, arguments: %{}}

      assert %Wardrik.Call{state: :denied, denied: %{by: "policy"}} = check.(tool.("run_lua"))
      assert %Wardrik.Call{state: :waiting, asks: [%{by: "policy"}]} = check.(tool.("deploy"))
      assert %Wardrik.Call{state: :allowed} = check.(tool.("web_search"))

      model =
        Wardrik.Call.model(Wardrik.LLM.Request.new(Config.new(), ReqLLM.Context.new()), scope)

      assert %Wardrik.Call{state: :allowed} = Wardrik.Hook.check(model)
    end

    test "reads a policy written as data, as its init/1" do
      assert %WardrikPolicy{} = WardrikPolicy.init(%{"deny" => ["run_lua"]})
      assert_raise ArgumentError, fn -> WardrikPolicy.init(%{"allows" => []}) end
    end

    test "is plain data, so it survives being written down" do
      policy = WardrikPolicy.decode!(@written, "careful")
      assert policy |> :erlang.term_to_binary() |> :erlang.binary_to_term() == policy
    end
  end

  describe "decode/2 and encode/1" do
    test "round-trip" do
      policy = WardrikPolicy.decode!(@written, "careful")

      assert policy.name == "careful"
      assert WardrikPolicy.encode(policy) == @written
    end

    test "refuse a key they do not know" do
      assert {:error, "allows is not a setting" <> _rest} =
               WardrikPolicy.decode(%{"allows" => []})
    end

    test "refuse a default that is not an effect" do
      assert {:error, "default is allow, ask or deny"} =
               WardrikPolicy.decode(%{"default" => "maybe"})
    end

    test "refuse a budget that sets nothing" do
      assert {:error, "budget is a set of settings" <> _rest} =
               WardrikPolicy.decode(%{"budget" => nil})

      assert {:ok, %WardrikPolicy{budget: nil}} = WardrikPolicy.decode(%{"default" => "allow"})
    end

    test "refuse rules that are not patterns" do
      assert {:error, "deny is a list" <> _rest} = WardrikPolicy.decode(%{"deny" => "run_lua"})
      assert {:error, "allow names" <> _rest} = WardrikPolicy.decode(%{"allow" => [7]})

      assert {:error, "ask gives x a message" <> _rest} =
               WardrikPolicy.decode(%{"ask" => %{"x" => 1}})
    end
  end
end
