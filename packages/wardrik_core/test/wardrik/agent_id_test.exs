defmodule Wardrik.AgentIDTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Thread

  import Wardrik.AgentID, only: [sigil_A: 2]

  describe "new/2" do
    test "names the org, then the user marked with @" do
      assert {:ok, id} = AgentID.new("researcher", org: "acme")
      assert to_string(id) == "acme/researcher"

      assert to_string(AgentID.new!("researcher", org: "acme", user: "jon")) ==
               "acme/@jon/researcher"
    end

    test "writes host values down through Wardrik.AgentID.Segment" do
      assert to_string(AgentID.new!("researcher", org: :acme, user: 7)) == "acme/@7/researcher"
    end

    test "needs an org" do
      assert {:error, "an agent's org is missing"} = AgentID.new("researcher", [])
      assert_raise ArgumentError, ~r/org is missing/, fn -> AgentID.new!("researcher", []) end
    end

    test "refuses a segment that is not one" do
      for opts <- [
            [org: "acme/eu"],
            [org: "_acme"],
            [org: "@acme"],
            [org: "acme", user: "jo n"],
            [org: "acme", user: ""],
            [org: "acme", user: "j?n"]
          ] do
        assert {:error, message} = AgentID.new("researcher", opts)
        assert message =~ "not a segment"
      end

      assert {:error, message} = AgentID.new("researcher", org: "deployment")
      assert message =~ "names the deployment itself"

      assert {:error, _message} = AgentID.new("acme/researcher", org: "acme")
      assert {:error, _message} = AgentID.new("@researcher", org: "acme")
    end

    test "a value with no Segment implementation says so" do
      assert_raise Protocol.UndefinedError, fn ->
        AgentID.new("researcher", org: "acme", user: %{id: 1})
      end
    end
  end

  describe "parse/1" do
    test "reads what to_string/1 writes" do
      for text <- ["acme/researcher", "acme/@jon/researcher"] do
        assert {:ok, id} = AgentID.parse(text)
        assert to_string(id) == text
      end

      assert {:ok, %AgentID{org: "acme", user: "jon", name: "researcher"}} =
               AgentID.parse("acme/@jon/researcher")
    end

    test "refuses anything new/2 would not have built" do
      for text <- [
            "researcher",
            "acme/books/t1",
            "a/b/c/d",
            "a/@b/c/d/e",
            "_/x",
            "a/@b",
            "@a/b",
            "a/_x",
            "a/ b",
            "deployment/x",
            "a/tri*ge",
            ""
          ] do
        assert {:error, message} = AgentID.parse(text)
        assert message =~ "not an agent ID"
        assert_raise ArgumentError, fn -> AgentID.parse!(text) end
      end
    end
  end

  test "address/1 reads an agent's text or a thread's" do
    assert AgentID.address("acme/@jon/books") == {:ok, ~A"acme/@jon/books"}
    assert AgentID.address("acme/@jon/books/t1") == {:ok, Thread.new!(~A"acme/@jon/books", "t1")}
    assert AgentID.address!("acme/books/t1") == Thread.new!(~A"acme/books", "t1")

    for text <- ["acme", "a/@b/c/d/e", "acme/books/t 1", "acme/@jon"] do
      assert {:error, message} = AgentID.address(text)
      assert message =~ "not an agent ID"
    end
  end

  describe "expand/2" do
    test "finds a name, or a user's name, in the org it is given" do
      assert AgentID.expand("triage", "default") == {:ok, ~A"default/triage"}
      assert AgentID.expand("@jon/triage", "default") == {:ok, ~A"default/@jon/triage"}
    end

    test "takes a whole ID as it is, a thread's among them" do
      assert AgentID.expand("acme/triage", "default") == {:ok, ~A"acme/triage"}
      assert AgentID.expand("acme/@jon/triage", nil) == {:ok, ~A"acme/@jon/triage"}

      assert AgentID.expand("acme/triage/C1-17.1", "default") ==
               {:ok, Thread.new!(~A"acme/triage", "C1-17.1")}
    end

    test "needs an org where the text names none" do
      assert {:error, message} = AgentID.expand("researcher", nil)
      assert message =~ "names no org"
    end

    test "refuses what names no agent" do
      for text <- ["", "@jon", "acme/@jon", "a/b/c/d", "_triage"] do
        assert {:error, message} = AgentID.expand(text, "default")
        assert message =~ "not an agent ID"
      end
    end
  end

  test "segment?/1 says what can be one part of an ID" do
    assert AgentID.segment?("acme")
    assert AgentID.segment?("1696.1234")
    refute AgentID.segment?("_acme")
    refute AgentID.segment?("@acme")
    refute AgentID.segment?("a/b")
    refute AgentID.segment?("..")
    refute AgentID.segment?("a*")
    refute AgentID.segment?("ssh:jon")
    refute AgentID.segment?(7)
    assert AgentID.org?("acme")
    refute AgentID.org?("deployment")
  end

  test "inspects as the sigil that writes it" do
    assert inspect(~A"acme/@jon/triage") == ~s(~A"acme/@jon/triage")
  end
end
