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
