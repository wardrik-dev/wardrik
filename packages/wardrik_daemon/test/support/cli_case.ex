defmodule WardrikDaemon.CLICase do
  @moduledoc """
  Writes a daemon's config.yaml, policy and agent file for each CLI test, with a test model, and
  the helpers that run the `wardrik` command. Its tests run across modules, side by side.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import ExUnit.CaptureIO
  import WardrikDaemon.Test

  alias WardrikDaemon.CLI

  using do
    quote do
      import ExUnit.CaptureIO
      import WardrikDaemon.CLICase
      import WardrikDaemon.Test

      alias WardrikDaemon.CLI
      alias WardrikDaemon.CLI.Init
      alias WardrikDaemon.CLI.Terminal
      alias WardrikDaemon.Test.Screen
    end
  end

  setup context do
    # Hours twelve hours off, in UTC and in Los Angeles, so a daily trigger at one is never due as
    # a test runs.
    la = DateTime.now!("America/Los_Angeles", Tz.TimeZoneDatabase)

    context =
      context
      |> dirs()
      |> fake_model()
      |> Map.merge(%{
        later: rem(DateTime.utc_now().hour + 12, 24),
        later_la: rem(la.hour + 12, 24)
      })

    write(context, "config.yaml", """
    org: acme
    orgs: {"*": {}, growth: {}}
    allow_private_urls: true
    http: {port: #{free_port()}}
    web: {enabled: false}
    #{context.models}
    defaults: {model: #{model()}, retries: {attempts: 0, on_exhausted: fail}}
    """)

    write(context, "policies/careful.yaml", "ask: [echo]\n")

    write(context, "agents/triage.md", """
    ---
    description: Triages.
    tools: [echo]
    policy: careful
    triggers:
      - {name: daily, every: "0 #{context.later} * * *", prompt: Go.}
    ---
    You watch the queue.
    """)

    context
  end

  @doc "The arguments of `wardrik init` that ask nothing."
  def init, do: ~w(init --provider anthropic --no-ask)

  def wardrik(context, argv, input \\ "") do
    output =
      capture_io(input, fn -> send(self(), {:status, CLI.main(argv, env: context.env)}) end)

    assert_received {:status, status}
    {status, output}
  end

  def failing(context, argv) do
    run = fn -> send(self(), {:status, CLI.main(argv, env: context.env)}) end
    stderr = capture_io(:stderr, fn -> capture_io("", run) end)

    assert_received {:status, 1}
    stderr
  end

  # Stands in for bin/wardrik, writing each command it's given to the log.
  def script(context) do
    script = Path.join(context.root, "wardrik")
    log = Path.join(context.root, "script.log")
    File.mkdir_p!(context.root)
    File.write!(script, "#!/bin/sh\necho \"$*\" >> '#{log}'\n")
    File.chmod!(script, 0o755)
    {put_in(context.env["WARDRIK_SCRIPT"], script), log}
  end

  # Waits for the test screen to show `text`.
  def screen(text, shown \\ "") do
    receive do
      {:screen, written} -> if written =~ text, do: written, else: screen(text, written)
      {:followed, status} -> flunk("It stopped following, with #{status}.")
    after
      5_000 -> flunk("The screen never showed #{inspect(text)}, only #{inspect(shown)}.")
    end
  end

  # An agent's activity is written from its events, a moment after its turn stops.
  def idle(context, agent) do
    events =
      context.wardrik
      |> Wardrik.Instance.fetch!()
      |> Wardrik.events()

    :ok = Wardrik.EventLog.subscribe(events, :all)
    idled(events, agent)
  end

  def idled(events, agent) do
    unless Wardrik.EventLog.activity(events, agent)["doing"] == [] do
      assert_receive {Wardrik.EventLog, _log, _event}, 5_000
      idled(events, agent)
    end
  end

  def answers(context, responses), do: Wardrik.Testing.Model.answer(context.fake, responses)

  def answer(text), do: response(ReqLLM.Context.assistant(text))

  def calling(id, name, args),
    do:
      response(
        ReqLLM.Context.assistant("",
          tool_calls: [ReqLLM.ToolCall.new(id, name, JSON.encode!(args))]
        )
      )

  def response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}
end
