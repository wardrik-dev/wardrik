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
        authorizer: {Wardrik.Test.Allow, []},
        name: :"wardrik #{context.test}",
        keys: [WardrikVault.generate_key()],
        egress: &Wardrik.Egress.any/1,
        oauth: [
          page: "https://agents.test/oauth",
          req_options: [plug: {Req.Test, __MODULE__}],
          client_name: "Acme Agents",
          resolver:
            {Wardrik.Test.OAuthApps,
             mail: [
               authorization_endpoint: "https://mail.test/authorize",
               token_endpoint: "https://mail.test/token",
               client_id: "wardrik"
             ]}
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
             Wardrik.Agent.authorization(scope, agent: "acme/@maria/mail", interrupt: "call_1")

    %{"state" => state} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:ok, _signed_in} =
             Wardrik.finish_sign_in(wardrik, %{"state" => state, "code" => "c"}, as: maria())

    assert %{"data" => %{"status" => "ok"}} = until("wardrik.tool_call.completed")
    until("wardrik.run.completed")
  end

  test "asks an agent about a webhook request that proves itself with the secret it holds", %{
    wardrik: wardrik,
    scope: scope
  } do
    answers([answer("Triaged.")])

    :ok =
      seal(wardrik, {"acme", "HOOK"}, "s3cret", :signing_secret)

    {:ok, %Wardrik.Agent{}} =
      Wardrik.Agent.define(scope, "acme/hooks",
        model: "anthropic:claude-haiku-4-5",
        triggers: [%{name: "issues", webhook: %{secret: "${HOOK}"}, prompt: "Triage it."}]
      )

    assert :ok =
             Wardrik.Hook.deliver(scope,
               agent: "acme/hooks",
               trigger: "issues",
               body: "{\"action\":\"opened\"}",
               headers: %{"Authorization" => "Bearer s3cret"}
             )

    assert %{"data" => %{"status" => "asked"}} = until("wardrik.trigger.fired")
    until("wardrik.run.completed")

    pid = Wardrik.Operations.Running.whereis(wardrik, "acme/hooks")
    assert [%{metadata: %{labels: ["outside"]}} | _rest] = WardrikCore.history(pid)

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Hook.deliver_with_secret(scope,
               agent: "acme/hooks",
               trigger: "issues",
               secret: "nope",
               body: "{}",
               headers: %{}
             )
  end

  test "gives the sign-in pages to mount only where it signs people in", %{wardrik: wardrik} do
    nobody = {Wardrik.HTTP, :nobody, []}

    assert Wardrik.sign_in_pages(wardrik, nobody) ==
             {WardrikOAuth.Plug, %{oauth: Wardrik.oauth(wardrik), principal: nobody}}

    assert Wardrik.sign_in_pages(
             Wardrik.new(authorizer: {Wardrik.Test.Allow, []}, name: MyApp.AgentRuntime),
             nobody
           ) == nil
  end

  test "finishes a sign-in for an app that serves the page itself", %{wardrik: wardrik} do
    assert Wardrik.finish_sign_in(wardrik, %{"state" => "nope", "code" => "c"}, as: maria()) ==
             {:error, :no_such_flow}

    assert %{"client_id" => "https://agents.test/oauth/client", "client_name" => "Acme Agents"} =
             Wardrik.client_document(wardrik)
  end

  test "keeps credentials only when given keys" do
    assert %Wardrik{keys: [], oauth: nil} =
             Wardrik.new(authorizer: {Wardrik.Test.Allow, []}, name: MyApp.AgentRuntime)

    assert_raise ArgumentError, fn ->
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        name: MyApp.AgentRuntime,
        oauth: [page: "https://agents.test/oauth", resolver: {Wardrik.Test.OAuthApps, []}]
      )
    end
  end

  test "keeps keys and secrets out of what it shows" do
    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        name: MyApp.AgentRuntime,
        keys: ["secret key"]
      )

    refute inspect(wardrik) =~ "secret key"
  end
end

defmodule Wardrik.OAuthResolverTest do
  use ExUnit.Case, async: false

  test "signs people in with the apps its oauth resolver gives them", context do
    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        name: :"wardrik #{context.test}",
        keys: [WardrikVault.generate_key()],
        oauth: [page: "https://agents.test/oauth", resolver: {__MODULE__, "maria-mail"}]
      )

    start_supervised!({Wardrik, wardrik})

    assert {:ok, url} =
             WardrikOAuth.authorize(Wardrik.oauth(wardrik), "mail", %WardrikCore.Principal{
               id: "acme/@maria"
             })

    assert URI.decode_query(URI.parse(url).query)["client_id"] == "maria-mail"
  end

  def provider(%{name: name}, client_id) do
    provider =
      WardrikOAuth.Provider.new(name,
        authorization_endpoint: "https://mail.test/authorize",
        token_endpoint: "https://mail.test/token",
        client_id: client_id
      )

    {:ok, %{provider | key: client_id}}
  end
end
