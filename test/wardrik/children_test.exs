defmodule Wardrik.ChildrenTest do
  use ExUnit.Case, async: false

  test "keeps agents in memory unless told where", %{test: test} do
    wardrik = Wardrik.new(name: :"own #{test}")
    start_supervised!({Wardrik, wardrik}, id: :own)

    assert %Wardrik{own_store: true, store: %WardrikStore{adapter: WardrikStore.ETS}} = wardrik

    assert {:ok, _agent} =
             Wardrik.start_agent(wardrik,
               agent_id: "acme/triage",
               model: "anthropic:claude-haiku-4-5"
             )
  end

  @tag :tmp_dir
  test "keeps agents on disk in a directory", %{test: test, tmp_dir: tmp_dir} do
    wardrik = Wardrik.new(name: :"disk #{test}", data_dir: tmp_dir)
    start_supervised!({Wardrik, wardrik}, id: :disk)

    assert %Wardrik{own_store: true, store: %WardrikStore{adapter: WardrikStore.EKV}} = wardrik

    assert {:ok, _agent} =
             Wardrik.start_agent(wardrik,
               agent_id: "acme/triage",
               model: "anthropic:claude-haiku-4-5"
             )
  end

  test "takes a store or a directory, not both" do
    assert_raise ArgumentError, fn ->
      Wardrik.new(name: MyApp.Wardrik, store: :store, data_dir: "/tmp/wardrik")
    end
  end

  test "connects to the MCP servers it's given", %{test: test} do
    wardrik =
      Wardrik.new(
        name: :"mcp #{test}",
        mcp: [down: [transport: {:stdio, command: "no-such-mcp-server"}]]
      )

    start_supervised!({Wardrik, wardrik}, id: :mcp)

    assert Process.whereis(Wardrik.mcp(wardrik))

    assert WardrikMCP.tools(nil, name: Wardrik.mcp(wardrik), servers: :down) == []
  end
end
