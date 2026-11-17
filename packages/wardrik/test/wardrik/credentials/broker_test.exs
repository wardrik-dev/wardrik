defmodule Wardrik.Credentials.BrokerTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Credentials.Broker
  alias Wardrik.Credentials.Endpoint
  alias Wardrik.Credentials.Request
  alias Wardrik.Triggers.Webhook

  defmodule Fallback do
    @moduledoc "Answers every credential the broker doesn't."
    @behaviour Wardrik.Credentials

    @impl true
    def resolve(%{name: name}, _opts), do: {:ok, "fallback #{name}"}
  end

  @secret "whsec_" <> Base.encode64("a broker's secret, 32 bytes long")

  setup :set_mimic_global
  setup {Req.Test, :set_req_test_to_shared}

  setup context do
    {:ok, answers} = Agent.start_link(fn -> [] end)
    {:ok, asked} = Agent.start_link(fn -> [] end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      headers = Map.new(conn.req_headers)

      :ok =
        Webhook.verify(%{body: body, headers: headers},
          verify: :standard,
          secret: @secret,
          now: DateTime.utc_now()
        )

      Agent.update(asked, &[JSON.decode!(body) | &1])
      Req.Test.json(conn, Agent.get_and_update(answers, fn [next | rest] -> {next, rest} end))
    end)

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"wardrik #{context.test}"},
        name: :"wardrik #{context.test}",
        credentials: {Fallback, []},
        broker: [
          url: "https://broker.test/credentials",
          secret: @secret,
          credentials: ["mail"],
          req_options: [plug: {Req.Test, __MODULE__}, retry: false]
        ]
      )

    start_supervised!({Wardrik, wardrik})
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    event_log = Wardrik.events(wardrik)
    :ok = Wardrik.EventLog.subscribe(event_log, :all)

    answering = fn list -> Agent.update(answers, fn _old -> list end) end
    asked = fn -> Agent.get(asked, &Enum.reverse/1) end

    %{wardrik: wardrik, scope: owner(wardrik), answering: answering, asked: asked}
  end

  defp resolve(wardrik, name, agent \\ "acme/@maria/mail") do
    request = %Request{name: name, principal: maria(), agent: agent, call: nil}
    Broker.resolve(request, wardrik.name)
  end

  defp refuse(wardrik, name) do
    request = %Request{name: name, principal: maria(), agent: "acme/@maria/mail", call: nil}
    Broker.report_refusal(request, wardrik.name)
  end

  defp sign_change(change) do
    body = JSON.encode!(change)
    headers = Webhook.sign(@secret, body)
    [body: body, headers: Map.new(headers)]
  end

  defp stub_models(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  test "parks a call on the broker's link, and carries on once the broker says it's granted",
       %{wardrik: wardrik, scope: scope, answering: answering, asked: asked} do
    stub_models([calling([call("call_1", "mail", %{})]), answer("Done.")])
    answering.([%{authorize: "https://broker.test/connect/mail"}, %{token: "tok"}])

    {:ok, _agent} =
      Wardrik.start_agent(wardrik,
        agent_id: "acme/@maria/mail",
        model: "anthropic:claude-haiku-4-5",
        principal: maria(),
        capabilities: [Wardrik.Test.Mail]
      )

    Wardrik.Agent.ask(scope, "acme/@maria/mail", "Read my mail")
    until("wardrik.run.interrupted")

    assert {:ok, %Wardrik.Authorization{url: "https://broker.test/connect/mail"}} =
             Wardrik.Agent.authorization(scope, agent: "acme/@maria/mail", interrupt: "call_1")

    assert :ok =
             Wardrik.Hook.broker(
               scope,
               sign_change(%{type: "granted", credential: "mail", principal: "acme/@maria"})
             )

    assert %{"data" => %{"status" => "ok"}} = until("wardrik.tool_call.completed")
    until("wardrik.run.completed")

    assert [
             %{
               "credential" => "mail",
               "principal" => "acme/@maria",
               "agent" => "acme/@maria/mail",
               "call" => "call_1",
               "refused" => false
             },
             %{"call" => "call_1"}
           ] = asked.()
  end

  test "keeps a token until it expires, for each agent", %{
    wardrik: wardrik,
    answering: answering,
    asked: asked
  } do
    answering.([%{token: "kept", expires_in: 60}, %{token: "other agent's"}, %{token: "once"}])

    assert resolve(wardrik, "mail") == {:ok, "kept"}
    assert resolve(wardrik, "mail") == {:ok, "kept"}

    assert resolve(wardrik, "mail", "acme/@maria/other") ==
             {:ok, "other agent's"}

    assert [_first, _other] = asked.()

    :ok = refuse(wardrik, "mail")
    assert resolve(wardrik, "mail") == {:ok, "once"}
    assert %{"refused" => true} = List.last(asked.())
  end

  test "forgets a revoked token, and refuses a change it can't verify", %{
    wardrik: wardrik,
    scope: scope,
    answering: answering,
    asked: asked
  } do
    answering.([%{token: "kept", expires_in: 60}, %{error: "Maria left."}])

    assert resolve(wardrik, "mail") == {:ok, "kept"}

    revoked = sign_change(%{type: "revoked"})
    forged = Keyword.put(revoked, :body, ~s({"type":"granted"}))
    assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Hook.broker(scope, forged)

    assert :ok =
             Wardrik.Hook.broker(
               scope,
               sign_change(%{type: "revoked", credential: "mail", principal: "acme/@maria"})
             )

    assert resolve(wardrik, "mail") == {:error, "Maria left."}
    assert [_first, _again] = asked.()
  end

  test "gives where to connect when the broker says, as well as what to send", %{
    wardrik: wardrik,
    answering: answering
  } do
    answering.([
      %{url: "https://tenant.test/mcp", headers: %{"x-api-key" => "k"}, expires_in: 60},
      %{token: "tok", url: "https://tenant.test/mcp"},
      %{headers: %{"x-api-key" => 1}}
    ])

    endpoint = %Endpoint{url: "https://tenant.test/mcp", headers: %{"x-api-key" => "k"}}
    assert resolve(wardrik, "mail") == {:ok, endpoint}
    assert resolve(wardrik, "mail") == {:ok, endpoint}

    assert resolve(wardrik, "mail", "acme/@maria/other") ==
             {:ok, %Endpoint{token: "tok", url: "https://tenant.test/mcp"}}

    assert {:error, "The credential broker's answer has no token" <> _} =
             resolve(wardrik, "mail", "acme/@maria/third")
  end

  test "hands the credentials it doesn't broker to the rest", %{wardrik: wardrik, asked: asked} do
    assert resolve(wardrik, "github") == {:ok, "fallback github"}
    assert asked.() == []
  end
end
