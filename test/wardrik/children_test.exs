defmodule Wardrik.ChildrenTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik, only: [seal: 4]

  test "keeps agents in memory unless told where", %{test: test} do
    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"own #{test}"},
        name: :"own #{test}"
      )

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
    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"disk #{test}"},
        name: :"disk #{test}",
        store: {WardrikStore.EKV, data_dir: tmp_dir}
      )

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

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"hosted #{test}"},
        name: :"hosted #{test}",
        store: store
      )

    start_supervised!({Wardrik, wardrik}, id: :hosted)

    assert {:ok, _agent} =
             Wardrik.start_agent(wardrik,
               agent_id: "acme/triage",
               model: "anthropic:claude-haiku-4-5"
             )
  end

  test "starts a store it's given built, where nothing else has", %{test: test} do
    store = WardrikStore.ETS.new(name: :"unstarted #{test}")

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"given #{test}"},
        name: :"given #{test}",
        store: store
      )

    start_supervised!({Wardrik, wardrik}, id: :given)

    assert {:ok, _vsn} = WardrikStore.put(store, "here", true)
  end

  test "connects to the MCP servers it's given", %{test: test} do
    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"mcp #{test}"},
        name: :"mcp #{test}",
        mcp: [down: [transport: {:stdio, command: "no-such-mcp-server"}]]
      )

    start_supervised!({Wardrik, wardrik}, id: :mcp)

    assert Process.whereis(Wardrik.mcp(wardrik))

    assert WardrikMCP.tools(nil, name: Wardrik.mcp(wardrik), servers: :down) == []
  end

  test "keeps no secret without keys to seal it with", %{test: test} do
    start_supervised!(
      {Wardrik,
       name: :"keyless #{test}",
       authorizer: {Wardrik.Test.Allow, []},
       resolver: {Wardrik.Test.Owned, :"keyless #{test}"}},
      id: :keyless
    )

    assert {:error, :no_keys} =
             Wardrik.Sealed.fetch(:"keyless #{test}", owner: "acme", name: "HOOK")

    assert Wardrik.Sealed.list(:"keyless #{test}") == []
    refute Wardrik.Sealed.holds?(:"keyless #{test}", owner: "acme", name: "HOOK", kind: :secret)
  end

  defp linear(url),
    do: [
      linear: [
        transport:
          {:streamable_http,
           url: url, headers: %{"authorization" => {:secret, "LINEAR_TOKEN"}, "x-plain" => "kept"}}
      ]
    ]

  defp keyed(test, mcp) do
    Wardrik.new(
      authorizer: {Wardrik.Test.Allow, []},
      resolver: {Wardrik.Test.Owned, :"keyed #{test}"},
      name: :"keyed #{test}",
      keys: [WardrikVault.generate_key()],
      mcp: mcp
    )
  end

  test "an MCP server it starts names the deployment's secrets in its headers, unread", %{
    test: test
  } do
    wardrik = keyed(test, [])
    start_supervised!({Wardrik, wardrik}, id: :keyed)
    :ok = seal(wardrik, {"deployment", "LINEAR_TOKEN"}, "lin_123", :header)

    wardrik = %{wardrik | mcp: linear("https://mcp.linear.test/mcp")}

    %{start: {WardrikMCP, :start_link, [opts]}} = Wardrik.Children.mcp_spec(wardrik)
    assert [linear: server] = opts[:servers]
    assert server[:owner] == "deployment"
    assert {:streamable_http, transport} = server[:transport]

    assert transport[:headers] == %{
             "authorization" => {:secret, "LINEAR_TOKEN"},
             "x-plain" => "kept"
           }

    assert opts[:secret].("deployment", "LINEAR_TOKEN") == {:ok, "lin_123"}
  end

  test "an MCP server it starts reads the secret its headers name as it connects again", %{
    test: test
  } do
    wardrik = keyed(test, linear(Wardrik.Test.Headers.start("/mcp")))
    start_supervised!({Wardrik, wardrik}, id: :keyed)

    :ok = seal(wardrik, {"deployment", "LINEAR_TOKEN"}, "Bearer lin_123", :header)
    assert_receive {:authorization, "/mcp", ["Bearer lin_123"]}, 5_000

    :ok = seal(wardrik, {"deployment", "LINEAR_TOKEN"}, "Bearer lin_456", :header)
    assert_receive {:authorization, "/mcp", ["Bearer lin_456"]}, 5_000

    :ok = seal(wardrik, {"acme", "LINEAR_TOKEN"}, "Bearer acme", :header)
    refute_receive {:authorization, "/mcp", ["Bearer acme"]}, 500
  end
end
