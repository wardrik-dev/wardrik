defmodule Wardrik.Chat.PromptsTest do
  use ExUnit.Case, async: true

  import Wardrik.EventLog.Test.Protocol

  alias Wardrik.EventLog.Encoder

  defmodule Sink do
    def handle_event(event, test), do: send(test, {:emitted, event})
  end

  test "suggests next steps as prompts.suggested in the run's conversation" do
    context =
      Wardrik.Context.new(
        agent_id: "acme/triage",
        conversation: "slack.T1.C1.1.1",
        span: WardrikCore.Span.root(),
        events: {Sink, self()}
      )

    assert Wardrik.Chat.Prompts.suggest_next(context, ["Draft the email", "Show the numbers"]) ==
             :ok

    assert_received {:emitted, event}
    assert [cloud_event] = Encoder.encode(event, "local")
    valid!(cloud_event)

    assert %{
             "type" => "wardrik.prompts.suggested",
             "conversation" => "slack.T1.C1.1.1",
             "data" => %{"prompts" => ["Draft the email", "Show the numbers"]}
           } = cloud_event
  end
end
