defmodule Wardrik.SignInsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  setup :set_mimic_global
  setup {Req.Test, :set_req_test_to_shared}

  setup context do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"access_token" => "mail_token", "expires_in" => 3600})
    end)

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        keys: [WardrikVault.generate_key()],
        egress: &Wardrik.Egress.any/1,
        oauth: [
          page: "https://agents.test/oauth",
          req_options: [plug: {Req.Test, __MODULE__}],
          providers: [
            mail: [
              authorization_endpoint: "https://mail.test/authorize",
              token_endpoint: "https://mail.test/token",
              client_id: "wardrik"
            ]
          ]
        ]
      )

    start_supervised!({Wardrik, wardrik})

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  test "carries on a call once its person has signed in", %{wardrik: wardrik, scope: scope} do
    answers([calling([call("call_1", "mail", %{})]), answer("Done.")])

    {:ok, _agent} =
      Wardrik.start_agent(wardrik,
        agent_id: "acme/@maria/mail",
        model: "anthropic:claude-haiku-4-5",
        principal: maria(),
        capabilities: [Wardrik.Test.Mail]
      )

    Wardrik.Agent.ask(scope, "acme/@maria/mail", "Read my mail")
    until("wardrik.run.interrupted")

    assert {:ok, %Wardrik.Authorization{url: url}} =
             Wardrik.Agent.authorization(scope, "acme/@maria/mail", "call_1")

    %{"state" => state} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:ok, _provider} =
             WardrikOAuth.finish(Wardrik.oauth(wardrik), %{"state" => state, "code" => "c"})

    assert %{"data" => %{"status" => "ok"}} = until("wardrik.tool_call.completed")
    until("wardrik.run.completed")
  end

  test "asks an agent about a webhook request that proves itself with the secret it holds", %{
    wardrik: wardrik,
    scope: scope
  } do
    answers([answer("Triaged.")])
    :ok = Wardrik.put_secret(wardrik, "acme", "HOOK", "s3cret")

    {:ok, %Wardrik.Agent{}} =
      Wardrik.Agent.define(scope, "acme/hooks",
        model: "anthropic:claude-haiku-4-5",
        triggers: [%{name: "issues", webhook: %{secret: "${HOOK}"}, prompt: "Triage it."}]
      )

    assert :ok =
             Wardrik.Hook.deliver(scope, "acme/hooks", "issues",
               body: "{\"action\":\"opened\"}",
               headers: %{"Authorization" => "Bearer s3cret"}
             )

    assert %{"data" => %{"status" => "asked"}} = until("wardrik.trigger.fired")
    until("wardrik.run.completed")

    pid = Wardrik.Operations.Running.whereis(wardrik, "acme/hooks")
    assert [%{metadata: %{labels: ["outside"]}} | _rest] = WardrikCore.history(pid)

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Hook.deliver_with_secret(scope, "acme/hooks", "issues", "nope",
               body: "{}",
               headers: %{}
             )
  end

  test "keeps, reads and removes an owner's secrets, and records it", %{
    wardrik: wardrik,
    scope: scope
  } do
    assert :ok = Wardrik.put_secret(wardrik, "acme", "crm-key", "s3cret")
    assert {:ok, "s3cret"} = Wardrik.fetch_secret(wardrik, "acme", "crm-key")
    assert {:ok, :secret, "s3cret", vsn} = Wardrik.lookup_secret(wardrik, "acme", "crm-key")
    assert :ok = Wardrik.put_secret(wardrik, "acme", "crm-key", "rotated", if_vsn: vsn)

    assert {"acme", "crm-key", :secret} in Wardrik.list_secrets(wardrik)
    assert Wardrik.list_secrets(wardrik, "acme") == ["crm-key"]

    assert :ok = Wardrik.delete_secret(wardrik, "acme", "crm-key")
    assert {:error, :not_found} = Wardrik.fetch_secret(wardrik, "acme", "crm-key")

    {:ok, %Wardrik.Page{events: changes}} = Wardrik.Audit.list(scope)

    assert ["wardrik.secret.stored", "wardrik.secret.stored", "wardrik.secret.removed"] =
             Enum.map(changes, & &1.type)
  end

  test "gives the sign-in pages to mount only where it signs people in", %{wardrik: wardrik} do
    assert Wardrik.sign_in_pages(wardrik) == {WardrikOAuth.Plug, Wardrik.oauth(wardrik)}
    assert Wardrik.sign_in_pages(Wardrik.new(name: MyApp.Wardrik)) == nil
  end

  test "keeps credentials only when given keys" do
    assert %Wardrik{keys: [], oauth: nil} = Wardrik.new(name: MyApp.Wardrik)

    assert_raise ArgumentError, fn ->
      Wardrik.new(name: MyApp.Wardrik, oauth: [page: "https://agents.test/oauth", providers: []])
    end
  end

  test "keeps keys and secrets out of what it shows" do
    wardrik = Wardrik.new(name: MyApp.Wardrik, keys: ["secret key"])

    refute inspect(wardrik) =~ "secret key"
  end
end
