defmodule Wardrik.MCP.ToolsTest do
  use Wardrik.MCPCase, async: true

  test "says which MCP isn't started" do
    assert_raise ArgumentError, ~r/^MyApp.Missing isn't started/, fn ->
      Wardrik.MCP.servers(MyApp.Missing)
    end
  end

  test "offers a server's tools under its name" do
    names =
      :stub
      |> tools()
      |> Enum.map(& &1.name)

    assert "stub__echo" in names
    assert "stub__charge" in names
  end

  test "offers only the tools a server is given" do
    cheap =
      :cheap
      |> tools()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert ["cheap__charge", "cheap__echo"] = cheap

    metered =
      :metered
      |> tools()
      |> Enum.map(& &1.name)

    refute "metered__slow" in metered
  end

  test "gives several servers' tools together" do
    assert length(Wardrik.MCP.tools(context(), name: @mcp, servers: [:stub, :cheap])) ==
             length(tools(:stub)) + length(tools(:cheap))
  end

  test "carries the server's hints as annotations" do
    echo = tool(:stub, "echo")
    charge = tool(:stub, "charge")

    assert true == Tool.annotation(echo, :read_only)
    assert true == Tool.annotation(echo, :idempotent)
    assert false == Tool.annotation(charge, :read_only)
    assert true == Tool.annotation(charge, :destructive)
    assert nil == Tool.annotation(charge, :idempotent)
    boom = tool(:stub, "boom")
    assert nil == Tool.annotation(boom, :read_only)
  end

  test "gates a tool unless it's read-only, and labels answers outside unless trusted" do
    echo = tool(:stub, "echo")
    charge = tool(:stub, "charge")
    boom = tool(:stub, "boom")

    assert false == Tool.annotation(echo, :gated)
    assert true == Tool.annotation(charge, :gated)
    assert true == Tool.annotation(boom, :gated)
    assert ["outside"] == Tool.annotation(echo, :labels)

    cheap_echo = tool(:cheap, "echo")
    cheap_charge = tool(:cheap, "charge")

    assert true == Tool.annotation(cheap_echo, :gated)
    assert false == Tool.annotation(cheap_charge, :gated)
    assert [] == Tool.annotation(cheap_echo, :labels)
  end

  test "a call answers with the server's text" do
    assert {:ok, "hello", %Context{}} = call(:stub, "echo", %{"value" => "hello"})
  end

  test "a call the tool refuses answers with its error" do
    assert {:error, "the tool refused", %Context{}} = call(:stub, "boom")
  end

  test "structured content is given as it is" do
    assert {:ok, %{"open" => 3}, _context} = call(:stub, "report")
  end

  test "a long result is cut, and the model is told" do
    assert {:ok, text, _context} = call(:hasty, "big")
    assert String.valid?(text)
    assert text =~ "[Cut to 101 of 2000 bytes.]"
  end

  test "a call that fails in passing raises, for the tool runner to try again" do
    assert_raise Wardrik.MCP.UnavailableError, ~r/hasty failed/, fn -> call(:hasty, "slow") end
  end

  test "a server's cost is measured on the call's step" do
    assert {:ok, "charged", %Context{measurements: %{usd: 0.01}}} = call(:cheap, "charge")
    assert {:ok, "charged", %Context{measurements: %{usd: 0.25}}} = call(:metered, "charge")
    assert {:ok, "charged", %Context{measurements: measured}} = call(:stub, "charge")
    assert measured == %{}
  end

  test "a server that's down offers no tools" do
    assert [] = tools(:down)
  end

  test "the arguments are checked against the server's schema" do
    calls = [%ToolCall{id: "1", name: "stub__echo", arguments: %{}}]
    stub = tools(:stub)
    assert {:error, _reason} = Tool.call(stub, hd(calls), context())
  end

  test "a server that says its tools changed is asked for them again" do
    listen()
    refute tool(:growing, "grown")
    assert {:ok, "grown", _context} = call(:growing, "grow")

    assert_receive {:tools, @mcp, "growing", %{count: 10}}, 5_000
    assert tool(:growing, "grown")
    refute_receive {:tools, @mcp, "stub", _measured}, 200
  end

  test "a connection that dies offers nothing, then connects again" do
    listen()
    {:ok, client} = flaky_client()
    Process.exit(client, :kill)

    assert_receive {:tools, @mcp, "flaky", %{count: 0}}, 5_000
    assert_receive {:tools, @mcp, "flaky", %{count: count}}, 5_000
    assert count > 0
    assert {:ok, "back", _context} = call(:flaky, "echo", %{"value" => "back"})
  end

  test "keeps the servers of each Wardrik.MCP apart" do
    listen()

    start_supervised!(
      {Wardrik.MCP,
       name: Wardrik.MCPCase.Other, servers: [stub: [transport: @stub, only: ["echo"]]]},
      id: :other
    )

    assert_receive {:tools, Wardrik.MCPCase.Other, "stub", %{count: 1}}, 10_000

    other = Wardrik.MCP.tools(context(), name: Wardrik.MCPCase.Other, servers: :stub)
    assert ["stub__echo"] = Enum.map(other, & &1.name)

    stub = tools(:stub)
    assert "stub__charge" in Enum.map(stub, & &1.name)
  end
end
