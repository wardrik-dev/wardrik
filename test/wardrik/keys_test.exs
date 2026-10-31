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

  defp linear(url),
    do: [
      linear: [
        transport:
          {:streamable_http,
           url: url, headers: %{"authorization" => {:secret, "LINEAR_TOKEN"}, "x-plain" => "kept"}}
      ]
    ]

  test "an MCP server it starts names the deployment's secrets in its headers, unread", %{
    wardrik: wardrik
  } do
    :ok = Wardrik.put_secret(wardrik, "deployment", "LINEAR_TOKEN", "lin_123")
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

  test "an MCP server it starts reads the secret its headers name as it connects, so a new one takes effect at once",
       %{wardrik: wardrik} do
    url = Wardrik.Test.Headers.start("/mcp")
    :ok = stop_supervised!(Wardrik)
    start_supervised!({Wardrik, %{wardrik | mcp: linear(url)}})

    :ok = Wardrik.put_secret(wardrik, "deployment", "LINEAR_TOKEN", "Bearer lin_123")
    assert_receive {:authorization, "/mcp", ["Bearer lin_123"]}, 5_000

    :ok = Wardrik.put_secret(wardrik, "deployment", "LINEAR_TOKEN", "Bearer lin_456")
    assert_receive {:authorization, "/mcp", ["Bearer lin_456"]}, 5_000

    :ok = Wardrik.put_secret(wardrik, "acme", "LINEAR_TOKEN", "Bearer acme")
    refute_receive {:authorization, "/mcp", ["Bearer acme"]}, 500
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
