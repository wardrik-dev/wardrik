defmodule WardrikPolicy.ConditionTest do
  use ExUnit.Case, async: true

  alias WardrikPolicy.Condition
  alias WardrikPolicy.Pattern

  defp held(source, arguments) do
    {:ok, conditions} = Condition.parse(source)
    Condition.held(conditions, arguments)
  end

  describe "parse/1" do
    test "reads conditions, and leaves what a call acts on as a subject" do
      assert {:ok, [%Condition{path: ["amount"], test: {:gt, 500}}]} =
               Condition.parse("amount > 500")

      assert {:ok, [%Condition{path: ["vendor", "name"], test: {:is, ["acme", ""], nil}}]} =
               Condition.parse("vendor.name: Acme*")

      assert {:ok, [%{test: {:ge, 1.5}}, %{test: {:is, ["payroll"], nil}}]} =
               Condition.parse("amount >= 1.5, account: \"Payroll\"")

      for subject <- ["notes/*", "git diff *", "https://acme.com/*", "C:\\notes", "a, b", "", "*"] do
        assert Condition.parse(subject) == :subject, subject
      end
    end

    test "reads a value in double quotes whole, commas and spaces too" do
      assert {:ok, [%{test: {:is, [" a, b "], nil}}]} = Condition.parse(~s(memo: " a, b "))
      assert {:ok, [%{test: {:is, ["500"], nil}}]} = Condition.parse(~s(code: "500"))
      assert {:ok, [%{test: {:is, ["500"], 500}}]} = Condition.parse("code: 500")
    end

    test "says what does not read" do
      for {text, said} <- [
            {"amount > lots", "compares amount with \"lots\", which is not a number"},
            {"amount <", "compares amount with \"\""},
            {"account:", "gives account no value"},
            {~s(memo: "a" b"), "is not one value in double quotes"},
            {~s(memo: a"b), "a value in double quotes is quoted whole"},
            {"amount > 5, notes/*", "puts conditions beside what a call acts on"}
          ] do
        assert {:error, message} = Condition.parse(text)
        assert message =~ said, text
      end
    end
  end

  describe "held/2" do
    test "compares numbers, and text that reads whole as one" do
      assert held("amount > 500", %{"amount" => 501})
      refute held("amount > 500", %{"amount" => 500})
      assert held("amount >= 500", %{"amount" => 500.0})
      assert held("amount < 10.5", %{"amount" => " 10 "})
      assert held("amount <= -1", %{"amount" => "-1"})
    end

    test "matches a value with * and ignoring case, and a number as a number" do
      assert held("account: Payroll", %{"account" => "PAYROLL"})
      refute held("account: Payroll", %{"account" => "Payroll 2"})
      assert held("memo: refund*", %{"memo" => "Refund for March"})
      assert held("code: 500", %{"code" => 500.0})
      assert held("code: 500", %{"code" => "500"})
      assert held("paid: true", %{"paid" => true})
      assert held("count: 3*", %{"count" => 31})
    end

    test "is false for an argument the call leaves out or gives as null" do
      refute held("amount > 500", %{})
      refute held("amount > 500", %{"amount" => nil})
      refute held("vendor.name: Acme", %{"vendor" => %{}})
    end

    test "may hold for an argument it cannot be checked against" do
      assert held("amount > 500", %{"amount" => "six hundred"}) == :maybe
      assert held("amount > 500", %{"amount" => "$600"}) == :maybe
      assert held("amount > 500", %{"amount" => true}) == :maybe
      assert held("vendor: Acme", %{"vendor" => %{"name" => "Acme"}}) == :maybe
      assert held("vendor.name: Acme", %{"vendor" => "Acme"}) == :maybe
    end

    test "holds for a list where every item does, and may where some do" do
      assert held("to: *@acme.com", %{"to" => ["a@acme.com", "b@ACME.com"]})
      refute held("to: *@acme.com", %{"to" => ["a@other.com"]})
      refute held("to: *@acme.com", %{"to" => []})
      assert held("to: *@acme.com", %{"to" => ["a@acme.com", "b@other.com"]}) == :maybe

      lines = %{"lines" => [%{"amount" => 10}, %{"amount" => 900}]}
      assert held("lines.amount > 500", lines) == :maybe
      assert held("lines.amount > 5", lines)
    end

    test "holds where every condition does" do
      call = %{"amount" => 900, "account" => "Payroll"}

      assert held("amount > 500, account: Payroll", call)
      refute held("amount > 500, account: Rent", call)
      assert held("amount > 500, account: Payroll, memo: x", call) == false
      assert held("amount > 500, note > 1", Map.put(call, "note", "x")) == :maybe
      refute held("amount > 1000, note > 1", Map.put(call, "note", "x"))
    end
  end

  describe "in a pattern" do
    test "names the whole of a call, and never the tool by its name alone" do
      pattern = Pattern.parse!("books/create_bill(amount > 500)")

      assert Pattern.argument?(pattern)
      assert Pattern.whole(pattern, "books__create_bill", %{"amount" => 600})
      refute Pattern.whole(pattern, "books__create_bill", %{"amount" => 6})
      refute Pattern.whole(pattern, "books__pay", %{"amount" => 600})
      refute Pattern.match?(pattern, "books__create_bill")
      refute Pattern.match?(pattern, "books__create_bill", "600")
      assert Pattern.server(Pattern.parse!("books/*(account: Payroll)")) == nil
    end

    test "says what does not read, after the pattern" do
      assert {:error, message} = Pattern.parse("books/pay(amount > lots)")

      assert message ==
               ~s{"books/pay(amount > lots)", which compares amount with "lots", which is } <>
                 "not a number; >, >=, < and <= take one, as amount > 500"
    end
  end
end
