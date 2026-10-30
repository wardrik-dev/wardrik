defmodule Wardrik.ChildrenTest do
  use ExUnit.Case, async: false

  test "keeps agents in memory unless told where", %{test: test} do
    wardrik = Wardrik.new(name: :"own #{test}")
    start_supervised!({Wardrik, wardrik}, id: :own)

    assert %Wardrik{store: %WardrikStore{adapter: WardrikStore.ETS}} = wardrik

    assert {:ok, _agent} =
             Wardrik.start_agent(wardrik,
               agent_id: "acme/triage",
               model: "anthropic:claude-haiku-4-5"
             )
  end

  @tag :tmp_dir
  test "keeps agents on disk in a directory", %{test: test, tmp_dir: tmp_dir} do
    wardrik = Wardrik.new(name: :"disk #{test}", store: {WardrikStore.EKV, data_dir: tmp_dir})
    start_supervised!({Wardrik, wardrik}, id: :disk)

    assert %Wardrik{store: %WardrikStore{adapter: WardrikStore.EKV}} = wardrik

    assert {:ok, _agent} =
             Wardrik.start_agent(wardrik,
               agent_id: "acme/triage",
               model: "anthropic:claude-haiku-4-5"
             )
  end

  test "runs alongside a store the host runs", %{test: test} do
    store = WardrikStore.ETS.new(name: :"store #{test}")
    start_supervised!({WardrikStore, store}, id: :store)

    wardrik = Wardrik.new(name: :"hosted #{test}", store: store)
    start_supervised!({Wardrik, wardrik}, id: :hosted)

    assert {:ok, _agent} =
             Wardrik.start_agent(wardrik,
               agent_id: "acme/triage",
               model: "anthropic:claude-haiku-4-5"
             )
  end

  test "starts a store it's given built, where nothing else has", %{test: test} do
    store = WardrikStore.ETS.new(name: :"unstarted #{test}")
    wardrik = Wardrik.new(name: :"given #{test}", store: store)
    start_supervised!({Wardrik, wardrik}, id: :given)

    assert {:ok, _vsn} = WardrikStore.put(store, "here", true)
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

  test "keeps no secret without keys to seal it with", %{test: test} do
    start_supervised!({Wardrik, name: :"keyless #{test}"}, id: :keyless)
    assert {:error, :no_keys} = Wardrik.put_secret(:"keyless #{test}", "acme", "HOOK", "s3cret")
    assert {:error, :no_keys} = Wardrik.fetch_secret(:"keyless #{test}", "acme", "HOOK")
    assert Wardrik.list_secrets(:"keyless #{test}") == []
    assert Wardrik.list_secrets(:"keyless #{test}", "acme") == []
  end
end
