defmodule Wardrik.AgentID.PrefixTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix

  import Wardrik.AgentID, only: [sigil_A: 2]

  describe "covers?/2" do
    test "matches at segment boundaries" do
      acme = Prefix.new!(org: "acme")

      assert Prefix.covers?(acme, ~A"acme/@jon/triage")
      assert Prefix.covers?(acme, ~A"acme/triage")
      refute Prefix.covers?(acme, ~A"acmecorp/triage")
      assert Prefix.covers?(Prefix.all(), ~A"globex/triage")
    end

    test "reaches one user's agents" do
      jon = Prefix.new!(org: "acme", user: "jon")

      assert Prefix.covers?(jon, ~A"acme/@jon/triage")
      refute Prefix.covers?(jon, ~A"acme/@sam/triage")
      refute Prefix.covers?(jon, ~A"acme/triage")
    end

    test "reaches one agent with every external ID it answers for" do
      books = Prefix.of(~A"acme/books")

      assert Prefix.covers?(books, ~A"acme/books")
      assert Prefix.covers?(books, ~A"acme/books/1696.1234")
      refute Prefix.covers?(books, ~A"acme/books2")
      refute Prefix.covers?(books, ~A"acme/@jon/books")
      refute Prefix.covers?(Prefix.of(~A"acme/books/t1"), ~A"acme/books")
    end
  end

  describe "new/1" do
    test "writes host values down through Wardrik.AgentID.Segment" do
      assert to_string(Prefix.new!(org: :acme, user: 7)) == "acme/@7/"
      assert Prefix.new([]) == {:ok, Prefix.all()}
    end

    test "refuses a user without an org, and segments that are not ones" do
      assert {:error, _message} = Prefix.new(user: "jon")
      assert {:error, _message} = Prefix.new(org: "_acme")
      assert {:error, _message} = Prefix.new(org: "acme", user: "jo n")
    end
  end

  describe "parse/1" do
    test "reads an org, a user or an ID, as the prefix it is" do
      assert Prefix.parse("") == {:ok, Prefix.all()}
      assert Prefix.parse("acme") == {:ok, Prefix.new!(org: "acme")}
      assert Prefix.parse("acme/") == {:ok, Prefix.new!(org: "acme")}
      assert Prefix.parse("acme/@jon") == {:ok, Prefix.new!(org: "acme", user: "jon")}
      assert Prefix.parse("acme/triage") == {:ok, Prefix.of(~A"acme/triage")}
      assert Prefix.parse("acme/@jon/triage/") == {:ok, Prefix.of(~A"acme/@jon/triage")}
    end

    test "refuses what is neither a prefix nor an ID" do
      for text <- ["/acme", "acme/@/", "@jon/", "a/@b/c/d/e", "_x/"] do
        assert {:error, message} = Prefix.parse(text)
        assert message =~ "not a prefix"
      end
    end

    test "writes back what it reads" do
      for text <- ["", "acme/", "acme/@jon/", "acme/triage", "acme/books/t1"] do
        assert text |> Prefix.parse!() |> to_string() == text
      end
    end
  end

  describe "expand/2" do
    test "reads an org, a user, or a user in the org it is given" do
      assert Prefix.expand("", "default") == {:ok, Prefix.all()}
      assert Prefix.expand("acme/", "default") == {:ok, Prefix.new!(org: "acme")}

      assert Prefix.expand("acme/@jon/", "default") ==
               {:ok, Prefix.new!(org: "acme", user: "jon")}

      assert Prefix.expand("@jon/", "default") == {:ok, Prefix.new!(org: "default", user: "jon")}
    end

    test "reads anything else as an agent" do
      assert Prefix.expand("triage", "default") == {:ok, Prefix.of(~A"default/triage")}
      assert Prefix.expand("acme/@jon/triage", nil) == {:ok, Prefix.of(~A"acme/@jon/triage")}
      assert {:error, _message} = Prefix.expand("_x/", "default")
      assert {:error, _message} = Prefix.expand("@jon/", nil)
    end
  end

  test "inspects as the text it writes" do
    assert inspect(Prefix.new!(org: "acme")) == "#Wardrik.AgentID.Prefix<acme/>"
  end
end
