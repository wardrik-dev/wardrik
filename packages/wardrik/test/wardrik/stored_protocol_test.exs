defmodule Wardrik.StoredProtocolTest do
  use ExUnit.Case, async: true

  import Wardrik.EventLog.Test.Protocol

  alias ReqLLM.Message.ContentPart
  alias Wardrik.EventLog.Encoder
  alias Wardrik.Policy.Ask
  alias WardrikCore.Agent.State
  alias WardrikCore.Authorization
  alias WardrikCore.Event
  alias WardrikCore.Principal
  alias WardrikCore.Span
  alias WardrikCore.ToolCall

  # What an agent keeps must show as the protocol shows it before it was kept, so a restart
  # never changes what people see.

  @middleware [{Wardrik.Policy.Middleware, []}]
  @span %Span{id: "00f067aa0ba902b7", trace: "4bf92f3577b34da6a3ce929d0e0e4736"}

  defp kept(state) do
    state
    |> State.dump()
    |> JSON.encode!()
    |> JSON.decode!()
    |> State.load()
    |> State.configure(middleware: @middleware)
  end

  defp waiting(reason, messages \\ []) do
    context = WardrikCore.Context.new(agent_id: "acme/triage", middleware: @middleware)

    parked = %{
      reason: reason,
      messages: messages,
      metadata: %{},
      span: Span.root(),
      measurements: %{usd: 0.01}
    }

    %{
      State.new(agent_id: "acme/triage", model: "anthropic:claude-haiku-4-5", context: context)
      | state: :waiting,
        parked: parked
    }
  end

  defp shown(name, metadata) do
    event = %Event{
      name: [:wardrik_core | name],
      time: ~U[2026-11-13 12:00:00Z],
      metadata: Map.merge(%{agent_id: "acme/triage", span: @span}, metadata),
      measurements: %{}
    }

    for cloud_event <- Encoder.encode(event, "local") do
      valid!(cloud_event)
      Map.take(cloud_event, ["type", "data"])
    end
  end

  defp interrupts(state),
    do: shown([:turn, :stop], %{kind: :run, outcome: :park, reason: state.parked.reason})

  test "each reason an agent waits on shows the same once kept" do
    maria = %Principal{id: "user:maria", attributes: %{"name" => "Maria"}}

    reasons = [
      {:tool_calls,
       [
         {%ToolCall{id: "c1", name: "books__pay", arguments: %{"amount" => 1200}},
          {:park, %Ask{interrupt: "tool_approval", message: "Pay $1,200?", labels: ["outside"]}}},
         {%ToolCall{id: "c2", name: "github__list"},
          {:park, %Authorization{url: "https://x.test/1", credential: "github", principal: maria}}},
         {%ToolCall{id: "c3", name: "mail__send"}, {:park, :in_doubt}},
         {%ToolCall{id: "c4", name: "echo"}, {:ok, %{"said" => "done"}}},
         {%ToolCall{id: "c5", name: "claude", arguments: %{"task" => "Fix it."}},
          {:park,
           %Ask{
             interrupt: "tool_approval",
             message: "claude/execute needs your approval.",
             call: %ToolCall{id: "c5:t1", name: "claude__execute", arguments: %{"cmd" => "mix"}}
           }}}
       ]},
      %Ask{interrupt: "model_approval", message: "Over budget. Approve $5 more?"},
      %WardrikCore.Retry.Exhausted{message: "The model is down.", labels: ["outside"]}
    ]

    for reason <- reasons do
      state = waiting(reason)
      assert interrupts(kept(state)) == interrupts(state)
    end
  end

  test "each kind of message shows the same once kept" do
    messages = [
      ReqLLM.Context.user("Look it up.", %{
        id: "msg_1",
        sent_at: ~U[2026-11-13 12:00:00Z],
        principal: %Principal{id: "user:maria"}
      }),
      %ReqLLM.Message{
        role: :assistant,
        content: [
          %ContentPart{type: :thinking, text: "Search first.", metadata: %{signature: "s=="}},
          %ContentPart{type: :text, text: "Searching."},
          %ContentPart{type: :image_url, url: "https://x.test/a.png"},
          %ContentPart{type: :file, file_id: "file_1", media_type: "application/pdf"}
        ],
        tool_calls: [ReqLLM.ToolCall.new("call_1", "search", ~s({"q":"x"}))]
      },
      ReqLLM.Context.tool_result("call_1", "search", "found"),
      ReqLLM.Context.assistant("It's x.")
    ]

    state = waiting(:in_doubt, messages)
    completed = &shown([:turn, :stop], %{kind: :run, outcome: :ok, messages: &1.parked.messages})
    restored = kept(state)

    assert completed.(restored) == completed.(state)
  end
end
