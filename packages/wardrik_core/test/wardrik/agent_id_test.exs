defmodule Wardrik.AgentIDTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID

  import Wardrik.AgentID, only: [sigil_A: 2]

  describe "new/2" do
    test "names the org, the user marked with @, and the external ID last" do
      assert {:ok, id} = AgentID.new("researcher", org: "acme")
      assert to_string(id) == "acme/researcher"

      assert to_string(AgentID.new!("researcher", org: "acme", user: "jon")) ==
               "acme/@jon/researcher"

      assert to_string(AgentID.new!("books", org: "acme", external_id: "1696.1234")) ==
               "acme/books/1696.1234"

      assert to_string(AgentID.new!("books", org: "acme", user: "jon", external_id: "t1")) ==
               "acme/@jon/books/t1"
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
            [org: "acme", external_id: "a/b"],
            [org: "acme", external_id: "a*"],
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

  test "put_external_id/2 answers for one external ID" do
    id = ~A"acme/books" |> AgentID.put_external_id(1696)

    assert id == ~A"acme/books/1696"
    assert AgentID.put_external_id(id, nil) == ~A"acme/books"
    assert_raise ArgumentError, fn -> AgentID.put_external_id(id, "a b") end
  end

  describe "parse/1" do
    test "reads what to_string/1 writes" do
      for text <- ["acme/researcher", "acme/@jon/researcher", "acme/books/t1", "acme/@jon/b/t1"] do
        assert {:ok, id} = AgentID.parse(text)
        assert to_string(id) == text
      end

      assert {:ok, %AgentID{org: "acme", user: "jon", name: "researcher", external_id: nil}} =
               AgentID.parse("acme/@jon/researcher")

      assert {:ok, %AgentID{org: "acme", user: nil, name: "books", external_id: "t1"}} =
               AgentID.parse("acme/books/t1")
    end

    test "refuses anything new/2 would not have built" do
      for text <- [
            "researcher",
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

  describe "expand/2" do
    test "finds a name, or a user's name, in the org it is given" do
      assert AgentID.expand("triage", "default") == {:ok, ~A"default/triage"}
      assert AgentID.expand("@jon/triage", "default") == {:ok, ~A"default/@jon/triage"}
    end

    test "takes a whole ID as it is" do
      assert AgentID.expand("acme/triage", "default") == {:ok, ~A"acme/triage"}
      assert AgentID.expand("acme/@jon/triage", nil) == {:ok, ~A"acme/@jon/triage"}
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
