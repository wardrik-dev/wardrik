defmodule WardrikPolicyTest do
  use ExUnit.Case, async: true

  alias Wardrik.LLM.Config
  alias Wardrik.Run

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

  describe "decide/3" do
    setup do
      policy =
        WardrikPolicy.decode!(%{
          "allow" => ["shell(git status)", "shell(git diff *)"],
          "ask" => %{"shell(npm install *)" => "This installs packages."},
          "deny" => ["shell(git push *)"],
          "default" => "deny"
        })

      %{policy: policy}
    end

    test "allows a call every one of whose subjects a rule allows", %{policy: policy} do
      assert WardrikPolicy.decide(policy, "shell", ["git status"]) == :allow
      assert WardrikPolicy.decide(policy, "shell", ["git status", "git diff HEAD"]) == :allow
    end

    test "is decided by a deny or an ask speaking for any one subject", %{policy: policy} do
      assert {:deny, _reason} =
               WardrikPolicy.decide(policy, "shell", ["git status", "git push origin"])

      assert WardrikPolicy.decide(policy, "shell", ["git diff", "npm install left-pad"]) ==
               {:ask, "This installs packages."}
    end

    test "leaves a subject no rule allows to the default", %{policy: policy} do
      assert {:deny, _reason} = WardrikPolicy.decide(policy, "shell", ["git status", "ls"])
      assert {:deny, _reason} = WardrikPolicy.decide(policy, "shell", [])
    end

    test "lets a rule naming the tool whole speak for every subject" do
      policy = WardrikPolicy.decode!(%{"allow" => ["shell"], "deny" => ["shell(rm *)"]})

      assert WardrikPolicy.decide(policy, "shell", ["ls", "git status"]) == :allow
      assert {:deny, _reason} = WardrikPolicy.decide(policy, "shell", ["ls", "rm -rf x"])
    end
  end

  describe "decide/4" do
    setup do
      policy =
        WardrikPolicy.decode!(%{
          "allow" => ["books/list_*", "books/create_bill(amount < 100)"],
          "ask" => ["books/create_bill(amount >= 100)"],
          "deny" => %{"books/*(account = Payroll)" => "Payroll is not for this agent."},
          "default" => "ask"
        })

      %{policy: policy}
    end

    test "lets a rule's conditions on the arguments say which calls it speaks for", %{
      policy: policy
    } do
      assert WardrikPolicy.decide(policy, "books__create_bill", [], %{"amount" => 50}) == :allow

      assert {:ask, _prompt} =
               WardrikPolicy.decide(policy, "books__create_bill", [], %{"amount" => 500})

      assert {:deny, "Payroll is not for this agent."} =
               WardrikPolicy.decide(policy, "books__create_bill", [], %{
                 "amount" => 50,
                 "account" => "payroll"
               })
    end

    test "leaves a call that gives no such argument to the other rules", %{policy: policy} do
      assert WardrikPolicy.decide(policy, "books__list_bills", [], %{}) == :allow
      assert {:ask, _prompt} = WardrikPolicy.decide(policy, "books__create_bill", [], %{})
    end

    test "asks or denies a call it cannot check, and never allows one" do
      policy =
        WardrikPolicy.decode!(%{
          "allow" => ["books/create_bill(amount < 100)"],
          "deny" => ["books/pay(amount > 1000)"],
          "default" => "ask"
        })

      for amount <- ["fifty", "$50", true] do
        assert {:ask, _prompt} =
                 WardrikPolicy.decide(policy, "books__create_bill", [], %{"amount" => amount})

        assert {:deny, _reason} =
                 WardrikPolicy.decide(policy, "books__pay", [], %{"amount" => amount})
      end

      assert {:deny, _reason} =
               WardrikPolicy.decide(policy, "books__pay", [], %{"amount" => [5, 5000]})
    end

    test "denies a message with one recipient outside, and no message without a cc" do
      policy =
        WardrikPolicy.decode!(%{
          "deny" => ["email/send(to != *@example.com)", "email/send(cc != *@example.com)"],
          "default" => "ask"
        })

      inside = %{"to" => ["a@example.com"]}

      assert {:ask, _prompt} = WardrikPolicy.decide(policy, "email__send", [], inside)

      assert {:deny, _reason} =
               WardrikPolicy.decide(policy, "email__send", [], %{
                 "to" => ["a@example.com", "b@elsewhere.com"]
               })

      assert {:deny, _reason} =
               WardrikPolicy.decide(
                 policy,
                 "email__send",
                 [],
                 Map.put(inside, "cc", "c@else.com")
               )
    end
  end

  describe "allowing by name" do
    alias Wardrik.Test.Tools.Deploy

    defp checked(policy, target \\ "prod", labels \\ []) do
      hooks = WardrikPolicy.hooks(policy)

      run = %{
        Wardrik.Test.run(
          tools: [Deploy],
          id: Wardrik.AgentID.parse!("acme/triage"),
          hooks: hooks
        )
        | labels: labels
      }

      Wardrik.Test.check(run, "deploy", %{"target" => target})
    end

    test "is what an allow rule naming the call does, whole or by its subjects" do
      for allow <- ["deploy", "deploy(prod)", "deploy(*)", "*"] do
        assert %Wardrik.Call{state: :allowed, allowed: ["policy"]} =
                 checked(WardrikPolicy.decode!(%{"allow" => [allow]}))
      end
    end

    test "is what an allow_after rule does too, whole or by subject" do
      for allow <- ["deploy", "deploy(prod)"] do
        assert %Wardrik.Call{state: :allowed, allowed: ["policy"]} =
                 checked(WardrikPolicy.decode!(%{"allow_after" => %{"outside" => [allow]}}))
      end
    end

    test "after outside content holds a gated call for a person, unless an allow_after rule names it" do
      for {policy, state} <- [
            {%{"allow" => ["deploy"]}, :waiting},
            {%{"allow_after" => %{"outside" => ["deploy"]}}, :allowed},
            {%{"allow_after" => %{"outside" => ["deploy(prod)"]}}, :allowed},
            {%{"allow_after" => %{"outside" => ["deploy(staging)"]}, "allow" => ["deploy"]},
             :waiting},
            {%{"allow_after" => %{"outside" => ["deploy"]}, "ask" => ["deploy"]}, :waiting}
          ] do
        assert %Wardrik.Call{state: ^state} =
                 checked(WardrikPolicy.decode!(policy), "prod", ["outside"])
      end
    end

    test "says what it holds a call for" do
      assert %Wardrik.Call{asks: [%{by: "policy", prompt: prompt}]} =
               checked(WardrikPolicy.decode!(%{"allow" => ["deploy"]}), "prod", ["outside"])

      assert prompt ==
               "deploy is allowed, but this run has read content from outside, " <>
                 "which may be what asked for it."
    end

    test "holds after a label an allow_after rule names, and after no other" do
      policy =
        WardrikPolicy.decode!(%{"allow" => ["deploy"], "allow_after" => %{"books" => ["x"]}})

      assert %Wardrik.Call{state: :waiting, asks: [%{prompt: prompt}]} =
               checked(policy, "prod", ["books"])

      assert prompt =~ "this run has read content labelled books"

      assert %Wardrik.Call{state: :allowed} = checked(policy, "prod", ["pii"])

      unknown = WardrikPolicy.decode!(%{"allow" => ["deploy"]})
      assert %Wardrik.Call{state: :allowed} = checked(unknown, "prod", ["books"])
    end

    test "holds only a gated call: an ungated one goes ahead whatever the run has read" do
      policy = WardrikPolicy.decode!(%{"allow" => ["echo"]})

      run = %{
        Wardrik.Test.run(
          hooks: WardrikPolicy.hooks(policy),
          id: Wardrik.AgentID.parse!("acme/t")
        )
        | labels: ["outside"]
      }

      assert %Wardrik.Call{state: :allowed} = Wardrik.Test.check(run, "echo")
    end

    test "is not what default: allow does, so a gated tool asks under it as under nothing" do
      for policy <- [
            WardrikPolicy.decode!(%{}),
            WardrikPolicy.decode!(%{"allow" => ["deploy(staging)"]})
          ] do
        assert %Wardrik.Call{state: :waiting, allowed: [], asks: [%{by: :tool}]} = checked(policy)
      end
    end
  end

  describe "as a Wardrik.Hook" do
    test "decides tool calls through the seam, and allows every model call" do
      policy = WardrikPolicy.decode!(%{"deny" => ["run_lua"], "ask" => ["deploy"]})

      run =
        Run.root(Config.new(), Wardrik.AgentID.parse!("acme/triage"),
          hooks: WardrikPolicy.hooks(policy)
        )

      check = &(&1 |> Wardrik.Call.tool(run) |> Wardrik.Hook.check())
      tool = &%{id: "c1", name: &1, arguments: %{}}

      assert %Wardrik.Call{state: :denied, denied: %{by: "policy"}} = check.(tool.("run_lua"))
      assert %Wardrik.Call{state: :waiting, asks: [%{by: "policy"}]} = check.(tool.("deploy"))
      assert %Wardrik.Call{state: :allowed} = check.(tool.("web_search"))

      policy = WardrikPolicy.decode!(%{"deny" => ["books/pay(amount > 1000)"]})

      run =
        Run.root(Config.new(), Wardrik.AgentID.parse!("acme/triage"),
          hooks: WardrikPolicy.hooks(policy)
        )

      pay = &%{id: "c2", name: "books__pay", arguments: %{"amount" => &1}}

      assert %Wardrik.Call{state: :denied} =
               pay.(5000) |> Wardrik.Call.tool(run) |> Wardrik.Hook.check()

      assert %Wardrik.Call{state: :allowed} =
               pay.(50) |> Wardrik.Call.tool(run) |> Wardrik.Hook.check()

      model =
        Wardrik.Call.model(Wardrik.LLM.Request.new(Config.new(), Wardrik.Conversation.new()), run)

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

    test "round-trip conditions on the arguments as written" do
      written = %{"deny" => ["books/*(amount >= 1e3, memo = \"a, b\")"], "default" => "allow"}
      assert written |> WardrikPolicy.decode!() |> WardrikPolicy.encode() == written
    end

    test "refuse a key they do not know" do
      assert {:error, "allows is not a setting" <> _rest} =
               WardrikPolicy.decode(%{"allows" => []})
    end

    test "refuse a default that is not an effect" do
      for default <- ["maybe", "allow_after"] do
        assert {:error, "default is allow, ask or deny"} =
                 WardrikPolicy.decode(%{"default" => default})
      end
    end

    test "write rules that hold after a label under allow_after, by label" do
      written = %{
        "allow" => ["linear/*"],
        "allow_after" => %{
          "outside" => ["github/add_labels"],
          "books" => %{"quickbooks/read_*" => "Reading the books is fine."}
        },
        "default" => "allow"
      }

      assert written |> WardrikPolicy.decode!() |> WardrikPolicy.encode() == written
    end

    test "refuse an allow_after that is not a map of label to rules" do
      assert {:error, "allow_after is a map of label to tool patterns"} =
               WardrikPolicy.decode(%{"allow_after" => ["github/*"]})

      assert {:error, "allow_after names \"\", which is not a label"} =
               WardrikPolicy.decode(%{"allow_after" => %{"" => ["github/*"]}})

      assert {:error, "allow_after outside is a list" <> _rest} =
               WardrikPolicy.decode(%{"allow_after" => %{"outside" => "github/*"}})
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

      assert {:error, "deny lists books/*(account: Payroll), which YAML reads as a key" <> _rest} =
               WardrikPolicy.decode(%{"deny" => [%{"books/*(account" => "Payroll)"}]})
    end
  end
end
