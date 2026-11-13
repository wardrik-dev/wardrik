defmodule WardrikDaemon.CeilingTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias WardrikDaemon.Client
  alias WardrikDaemon.Tokens

  setup :set_mimic_global

  setup context do
    context = dirs(context)
    port = free_port()

    write(context, "config.yaml", """
    org: payments
    orgs:
      "*": {policy: cap}
      growth: {}
    http: {port: #{port}}
    defaults: {model: #{model()}}
    roles:
      reader: {rules: [{verbs: [read], kinds: [ceiling]}]}
    bindings:
      - {org: payments, role: reader, subjects: [user:payments/@ana]}
    """)

    write(
      context,
      "policies/cap.yaml",
      Map.get(context, :cap, "budget: {tokens: 100, per: month, on_exhausted: deny}\n")
    )

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    context = start_daemon(context)
    Map.put(context, :url, "http://127.0.0.1:#{port}")
  end

  defp answers(tokens) do
    {:ok, queue} = Agent.start_link(fn -> tokens end)

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      used = Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)
      message = ReqLLM.Context.assistant("Done.")

      {:ok,
       %ReqLLM.Response{
         id: "resp",
         model: "test",
         context: nil,
         message: message,
         usage: %{input_tokens: used, output_tokens: 0}
       }}
    end)
  end

  defp reply(context, owner, name) do
    Wardrik.Agent.reply(context.admin, agent(context, owner, name), "Go")
  end

  defp client(context, subject) do
    {:ok, %{secret: secret}} =
      Tokens.create(context.daemon_store,
        name: "test",
        subject: subject,
        expires: DateTime.add(DateTime.utc_now(), 1, :hour)
      )

    %Client{url: context.url, secret: secret}
  end

  defp ceilings(client, owner), do: Client.run(client, "ceilings.list", %{"owner" => owner})

  test "an org's agents stop at the ceiling they share, and another org's spend counts apart",
       context do
    ref = :telemetry_test.attach_event_handlers(self(), [[:wardrik_daemon, :ceiling, :reached]])
    answers([120, 30])

    assert {:ok, %Wardrik.Reply{}} = reply(context, "payments", "first")
    assert {:ok, %Wardrik.Reply{}} = reply(context, "growth", "first")

    assert {:error, %Wardrik.Error{message: message}} = reply(context, "payments/@ana", "second")
    assert message =~ "payments's agents have used 120 of 100 tokens this month"

    assert_received {[:wardrik_daemon, :ceiling, :reached], ^ref, _measurements,
                     %{org: "payments", ceiling: "cap", on_exhausted: :deny}}

    refute_received {[:wardrik_daemon, :ceiling, :reached], ^ref, _measurements, _metadata}

    ana = client(context, "user:payments/@ana")

    assert {:ok, %{"ceilings" => [cap]}} = ceilings(ana, "payments")

    assert %{
             "ceiling" => "cap",
             "per" => "month",
             "on_exhausted" => "deny",
             "limit" => %{"tokens" => 100},
             "spent" => %{"tokens" => 120},
             "granted" => %{},
             "starts_over" => _first_of_next_month
           } = cap

    admin = client(context, "user:admin")
    assert {:ok, %{"ceilings" => [%{"spent" => %{"tokens" => 30}}]}} = ceilings(admin, "growth")

    assert {:error, "not_found", _message} = ceilings(ana, "growth")
    assert {:error, "invalid_request", message} = ceilings(admin, "payments/@ana")
    assert message == "Ceilings belong to orgs. Ask for payments's ceilings."
    assert {:error, "not_found", _message} = ceilings(admin, "globex")
    assert {:error, "not_found", _message} = ceilings(admin, "deployment")
  end

  @tag cap: "budget: {tokens: 100, per: total}\n"
  test "asks past it, and whoever may decide on the agent approves more for the org", context do
    answers([120, 10])
    assert {:ok, %Wardrik.Reply{}} = reply(context, "payments", "first")
    second = agent(context, "payments", "second")

    event_log =
      context.wardrik
      |> Wardrik.Instance.fetch!()
      |> Wardrik.events()

    :ok = Wardrik.EventLog.subscribe(event_log, :all)

    {:ok, _asked} =
      Wardrik.run(context.admin, "agent.ask", %{"agent" => second, "content" => "Go"})

    assert %{"data" => %{"interrupts" => [%{"id" => "model", "reason" => "ceiling_approval"}]}} =
             until("wardrik.run.interrupted")

    {:ok, _approved} =
      Wardrik.run(context.admin, "agent.approve", %{
        "agent" => second,
        "interrupt" => "model"
      })

    until("wardrik.run.completed")

    assert {:ok, %{"ceilings" => [%{"spent" => %{"tokens" => 130}, "granted" => granted}]}} =
             ceilings(client(context, "user:admin"), "payments")

    assert %{"tokens" => _more} = granted
  end

  defp until(type) do
    receive do
      {Wardrik.EventLog, _log, %{"type" => ^type} = event} -> event
      {Wardrik.EventLog, _log, _event} -> until(type)
    after
      5_000 -> flunk("No #{type} came.")
    end
  end
end
