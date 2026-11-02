defmodule WardrikDaemon.KeysTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias WardrikCore.Principal
  alias WardrikDaemon.Keys

  setup :set_mimic_global

  setup context do
    context = dirs(context)

    write(context, "config.yaml", """
    org: acme
    orgs: {globex: {}}
    http: {port: #{free_port()}}
    defaults: {model: #{model()}}
    deployment_keys: #{Map.get(context, :deployment_keys, false)}
    """)

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    start_daemon(context)
  end

  defp seal(context, owner, value, kind \\ :api_key) do
    vault = context.wardrik |> Wardrik.Instance.fetch!() |> Wardrik.vault()

    secret = %WardrikVault.Secret{
      principal: %Principal{id: owner},
      name: "ANTHROPIC_API_KEY",
      value: value
    }

    {:ok, _vsn} = WardrikVault.put(vault, secret, kind: kind)
  end

  defp key_used(context, agent) do
    test = self()

    stub(ReqLLM, :stream_text, fn _model, _messages, opts ->
      send(test, {:api_key, opts[:api_key]})
      message = ReqLLM.Context.assistant("Done.")
      {:ok, %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}}
    end)

    {:ok, _defined} = Wardrik.Agent.define(context.admin, agent, model: model())
    {:ok, %Wardrik.Reply{}} = Wardrik.Agent.reply(context.admin, agent, "Go")
    assert_receive {:api_key, key}
    key
  end

  test "a model call takes its owner's key, then its org's, and never the deployment's",
       context do
    seal(context, "deployment", "sk-deployment")
    assert key_used(context, "acme/first") == nil

    seal(context, "acme", "sk-acme")
    seal(context, "acme/@maria", "sk-header", :header)
    assert key_used(context, "acme/second") == "sk-acme"
    assert key_used(context, "acme/@maria/third") == "sk-acme"

    seal(context, "acme/@maria", "sk-maria")
    assert key_used(context, "acme/@maria/fourth") == "sk-maria"
    assert key_used(context, "globex/fifth") == nil
  end

  @tag deployment_keys: true
  test "falls back to the deployment's keys with deployment_keys: true", context do
    seal(context, "deployment", "sk-deployment")
    assert key_used(context, "globex/first") == "sk-deployment"

    seal(context, "globex", "sk-globex")
    assert key_used(context, "globex/second") == "sk-globex"
  end

  test "names the owners whose keys an agent uses, nearest first" do
    assert Keys.owners(%Principal{id: "acme/@maria"}, false) == ["acme/@maria", "acme"]
    assert Keys.owners(%Principal{id: "acme"}, true) == ["acme", "deployment"]
    assert Keys.owners(%Principal{id: "deployment"}, false) == ["deployment"]
    assert Keys.owners(%Principal{id: "slack:T0/U1"}, false) == ["slack:T0/U1"]
    assert Keys.owners(nil, true) == ["deployment"]
    assert Keys.owners(nil, false) == []
  end
end
