defmodule WardrikDaemon.PolicyFileTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.PolicyFile

  @moduletag :tmp_dir

  defp read(text, %{tmp_dir: dir}) do
    path = Path.join(dir, "careful.yaml")
    File.write!(path, text)
    PolicyFile.read(path)
  end

  test "reads a policy named after its file", context do
    assert {:ok, %WardrikPolicy{name: "careful", default: :deny}} =
             read("default: deny\n", context)
  end

  test "a file that says nothing is refused", context do
    for text <- ["", "# nothing yet\n", "{}\n"] do
      assert {:error, message} = read(text, context)

      assert message =~
               "careful.yaml: is empty; a policy that allows every call says default: allow"
    end

    assert {:ok, %WardrikPolicy{rules: [], default: :allow}} = read("default: allow\n", context)
  end

  test "a file that is not YAML, or not a policy, says so", context do
    assert {:error, yaml} = read("deny: [a\n", context)
    assert yaml =~ "careful.yaml: is not YAML"

    assert {:error, policy} = read("allows: []\n", context)
    assert policy =~ "careful.yaml: allows is not a setting"
  end

  describe "conditions on a call's arguments, as YAML writes them" do
    test "read as a mapping's keys, * and all", context do
      assert {:ok, policy} =
               read(
                 """
                 deny:
                   books/*(account = Payroll): Payroll is not for this agent.
                   write_file(content = *password*): No secrets in files.
                   email/send(to != *@example.com): Mail stays inside.
                 """,
                 context
               )

      assert {:deny, "Payroll is not for this agent."} =
               WardrikPolicy.decide(policy, "books__pay", [], %{"account" => "payroll"})

      assert {:deny, "No secrets in files."} =
               WardrikPolicy.decide(policy, "write_file", [], %{"content" => "my password"})

      assert {:deny, "Mail stays inside."} =
               WardrikPolicy.decide(policy, "email__send", [], %{"to" => ["a@elsewhere.com"]})

      assert WardrikPolicy.decide(policy, "email__send", [], %{"to" => ["a@example.com"]}) ==
               :allow
    end

    test "read from a list a line at a time, or quoted in [ ]", context do
      for text <- [
            "deny:\n  - bank/transfer(amount > 5000, currency = USD)\n",
            ~s|deny: ["bank/transfer(amount > 5000, currency = USD)"]\n|,
            ~s|deny: ['bank/transfer(amount > 5000, currency = "USD")']\n|
          ] do
        assert {:ok, policy} = read(text, context)
        call = %{"amount" => 6000, "currency" => "usd"}

        assert {:deny, _reason} = WardrikPolicy.decide(policy, "bank__transfer", [], call),
               text

        assert WardrikPolicy.decide(policy, "bank__transfer", [], %{call | "amount" => 50}) ==
                 :allow
      end

      assert {:ok, policy} = read("deny: [email/send(to != *@example.com)]\n", context)

      assert {:deny, _reason} =
               WardrikPolicy.decide(policy, "email__send", [], %{"to" => "x@y.z"})
    end

    test "take a value with # or : in it quoted", context do
      assert {:ok, policy} =
               read(
                 """
                 deny:
                   - books/*(memo = "#123")
                   - 'books/*(memo = "a: b")'
                 """,
                 context
               )

      assert {:deny, _reason} =
               WardrikPolicy.decide(policy, "books__pay", [], %{"memo" => "#123"})

      assert {:deny, _reason} =
               WardrikPolicy.decide(policy, "books__pay", [], %{"memo" => "A: B"})
    end

    test "that YAML splits, or reads as a key and its value, say how to write them", context do
      assert {:error, split} =
               read("deny: [bank/transfer(amount > 5000, currency = USD)]\n", context)

      assert split =~
               ~s|deny names "bank/transfer(amount > 5000", which opens a parenthesis it never | <>
                 "closes; a [ ] list splits a rule at its commas, so quote a rule with several " <>
                 ~s|conditions there, as "tool(a > 1, b = 2)", or write the rules one to a line|

      assert {:error, comment} = read("deny:\n  - books/*(memo = #123)\n", context)
      assert comment =~ ~s|"books/*(memo =", which opens a parenthesis it never closes|

      assert {:error, keyed} = read("deny:\n  - books/*(account: Payroll)\n", context)

      assert keyed =~
               "deny lists books/*(account: Payroll), which YAML reads as a key and its value; " <>
                 "a condition on a value is written with =, and a rule with \": \" in it is quoted whole"

      assert {:error, colon} = read(~s|deny: ["books/*(account: Payroll)"]\n|, context)

      assert colon =~
               ~s|"books/*(account: Payroll)", which writes account: Payroll; | <>
                 "a condition on a value is account = Payroll"

      assert {:error, yaml} = read("deny:\n  books/*(account: Payroll): No.\n", context)
      assert yaml =~ "is not YAML"
    end
  end

  test "a file that is not there says so", %{tmp_dir: dir} do
    assert {:error, message} = PolicyFile.read(Path.join(dir, "missing.yaml"))
    assert message =~ "missing.yaml: no such file"
  end
end
