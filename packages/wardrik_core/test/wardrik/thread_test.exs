defmodule Wardrik.ThreadTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentAddress
  alias Wardrik.Resource
  alias Wardrik.Thread

  import Wardrik.AgentID, only: [sigil_A: 2]

  test "new/2 writes the thread's ID down through Wardrik.AgentID.Segment" do
    assert {:ok, %Thread{agent: ~A"acme/books", id: "1696"}} = Thread.new(~A"acme/books", 1696)
    assert {:error, message} = Thread.new(~A"acme/books", "a/b")
    assert message =~ "not a segment"
    assert_raise ArgumentError, fn -> Thread.new!(~A"acme/books", "a b") end
  end

  test "parse/1 reads what to_string/1 writes, and nothing else" do
    for text <- ["acme/books/C1-1.1", "acme/@jon/books/t1"] do
      assert text |> Thread.parse!() |> to_string() == text
    end

    for text <- ["acme/books", "acme/@jon/books", "acme/books/a/b", "acme/books/_t", ""] do
      assert {:error, message} = Thread.parse(text)
      assert message =~ "not a thread's ID"
    end
  end

  test "is addressed as a resource under its agent, and reads through to it" do
    thread = Thread.new!(~A"acme/@jon/books", "C1-1.1")

    assert AgentAddress.resource(thread) ==
             Resource.parse!("acme/@jon/agent/books/thread/C1-1.1")

    assert AgentAddress.agent(thread) == ~A"acme/@jon/books"
    assert AgentAddress.agent(~A"acme/books") == ~A"acme/books"
    assert inspect(thread) == "#Wardrik.Thread<acme/@jon/books/C1-1.1>"
  end
end
