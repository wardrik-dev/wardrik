defmodule Wardrik.KeysTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias WardrikCore.Principal

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global

  setup context do
    wardrik = Wardrik.new(name: :"wardrik #{context.test}", keys: [WardrikVault.generate_key()])
    start_supervised!({Wardrik, wardrik})
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp key_used(scope, agent) do
    test = self()

    stub(ReqLLM, :stream_text, fn _model, _messages, opts ->
      send(test, {:api_key, opts[:api_key]})
      {:ok, answer("Done.")}
    end)

    {:ok, _defined} = Wardrik.Agent.define(scope, agent, model: @model)
    {:ok, %Wardrik.Reply{}} = Wardrik.Agent.reply(scope, agent, "Go")
    assert_receive {:api_key, key}
    key
  end

  test "a model call takes its owner's key, then its org's, then the deployment's", %{
    wardrik: wardrik,
    scope: scope
  } do
    assert key_used(scope, "acme/first") == nil

    :ok = Wardrik.put_secret(wardrik, "deployment", "ANTHROPIC_API_KEY", "sk-deployment")
    assert key_used(scope, "acme/second") == "sk-deployment"

    :ok = Wardrik.put_secret(wardrik, "acme", "ANTHROPIC_API_KEY", "sk-acme")
    assert key_used(scope, "acme/third") == "sk-acme"
    assert key_used(scope, "acme/@maria/fourth") == "sk-acme"

    :ok = Wardrik.put_secret(wardrik, "acme/@maria", "ANTHROPIC_API_KEY", "sk-maria")
    assert key_used(scope, "acme/@maria/fifth") == "sk-maria"
    assert key_used(scope, "globex/sixth") == "sk-deployment"
  end

  test "a key is read as it's used, so a new one takes effect at once", %{
    wardrik: wardrik,
    scope: scope
  } do
    :ok = Wardrik.put_secret(wardrik, "acme", "ANTHROPIC_API_KEY", "sk-old")
    assert key_used(scope, "acme/bot") == "sk-old"

    :ok = Wardrik.put_secret(wardrik, "acme", "ANTHROPIC_API_KEY", "sk-new")
    {:ok, %Wardrik.Reply{}} = Wardrik.Agent.reply(scope, "acme/bot", "Again")
    assert_receive {:api_key, "sk-new"}
  end

  defmodule Headers do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(test), do: test

    @impl Plug
    def call(conn, test) do
      send(test, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
      Plug.Conn.send_resp(conn, 503, "")
    end
  end

  defp linear(url),
    do: [
      linear: [
        transport:
          {:streamable_http,
           url: url, headers: %{"authorization" => {:secret, "LINEAR_TOKEN"}, "x-plain" => "kept"}}
      ]
    ]

  test "an MCP server's headers name the deployment's secrets, read as its servers start", %{
    wardrik: wardrik
  } do
    :ok = Wardrik.put_secret(wardrik, "deployment", "LINEAR_TOKEN", "lin_123")
    wardrik = %{wardrik | mcp: linear("https://mcp.linear.test/mcp")}

    %{start: {WardrikMCP, :start_link, [opts]}} = Wardrik.Children.mcp_spec(wardrik)
    assert [linear: [transport: {:streamable_http, transport}]] = opts[:servers]
    assert transport[:headers] == %{"authorization" => "lin_123", "x-plain" => "kept"}
  end

  test "an MCP server it starts is reached with the secret its headers name", %{
    wardrik: wardrik
  } do
    server = start_supervised!({Bandit, plug: {Headers, self()}, ip: :loopback, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    :ok = stop_supervised!(Wardrik)
    store = Wardrik.Test.Store.new(:"linear #{wardrik.name}")
    start_supervised!({WardrikStore, store})
    wardrik = %{wardrik | store: store, backend: {WardrikStore.Durable, store: store}}

    start_supervised!({Wardrik, wardrik})
    :ok = Wardrik.put_secret(wardrik, "deployment", "LINEAR_TOKEN", "Bearer lin_123")
    :ok = stop_supervised!(Wardrik)

    start_supervised!({Wardrik, %{wardrik | mcp: linear("http://localhost:#{port}/mcp")}})
    assert_receive {:authorization, ["Bearer lin_123"]}, 1_000
  end

  test "an owner's keys reach no tool's credentials, and the deployment's reach no owner", %{
    wardrik: wardrik
  } do
    :ok = Wardrik.put_secret(wardrik, "deployment", "ZAI_API_KEY", "sk-deployment")
    vault = Wardrik.vault(wardrik)

    assert {:error, _none} = WardrikVault.resolve("ZAI_API_KEY", %Principal{id: "acme"}, vault)

    assert Wardrik.Keys.fetch("ZAI_API_KEY", %Principal{id: "acme"}, vault) ==
             {:ok, "sk-deployment"}
  end
end
