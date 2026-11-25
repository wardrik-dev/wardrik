defmodule WardrikDaemon.NotifyAgentTest do
  use ExUnit.Case, async: true

  import WardrikDaemon.Test

  alias WardrikDaemon.NotifyAgent

  setup context do
    context = fake_model(dirs(context))

    write(context, "config.yaml", """
    org: acme
    orgs: {acme: {notify: [lead]}, growth: {notify: [lead]}}
    http: {port: #{free_port()}}
    web: {enabled: false}
    #{context.models}
    defaults: {model: #{model()}}
    notify:
      targets:
        lead: {agent: assistant}
    """)

    write(context, "agents/assistant.md", "---\ndescription: The assistant.\n---\nYou lead.\n")

    watcher = """
    notify:
      - {to: [lead], on: [finished]}
    ---
    You watch.
    """

    write(context, "agents/watcher.md", "---\n" <> watcher)
    write(context, "agents/scout.md", "---\norg: growth\n" <> watcher)

    start_daemon(context)
  end

  defp answer(text),
    do: %ReqLLM.Response{
      id: "resp",
      model: "test",
      context: nil,
      message: ReqLLM.Context.assistant(text)
    }

  defp receive_message(agent) do
    receive do
      {Wardrik.EventLog, {^agent, _conversation},
       %{"type" => "wardrik.message.created", "data" => %{"message" => message}}} ->
        message["parts"]
    after
      5_000 -> flunk("#{agent} was sent no message.")
    end
  end

  test "tells the agent of the name in the notifying agent's org", context do
    Wardrik.Testing.Model.answer(context.fake, [answer("Two new posts."), answer("Noted.")])

    events =
      context.wardrik
      |> Wardrik.Instance.fetch!()
      |> Wardrik.events()

    :ok = Wardrik.EventLog.subscribe(events, :all)
    watcher = id(context, "acme", "watcher")
    {:ok, _reply} = Wardrik.Agent.reply(context.admin, watcher, "Look.")

    assert [%{"content" => content}] = receive_message(id(context, "acme", "assistant"))

    assert content ==
             "From agent watcher (#{watcher}):\nIt finished a turn, and answered:\nTwo new posts."
  end

  test "skips an org with no agent of the name", context do
    notice = %Wardrik.Notice{
      agent: id(context, "growth", "scout"),
      kind: :finished,
      at: DateTime.utc_now(),
      text: "Two new posts."
    }

    assert NotifyAgent.deliver(notice, name: "assistant", wardrik: context.wardrik) ==
             {:skip, "but there's no agent assistant in its org"}
  end
end
