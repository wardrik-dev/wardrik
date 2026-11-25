defmodule Wardrik.Chat.NextStepsTest do
  use ExUnit.Case, async: true

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Testing.Model

  # The middleware the chat guide shows, as written there.
  defmodule NextSteps do
    @behaviour Wardrik.Middleware

    @tool "suggest_next_steps"

    @impl true
    def call(%Wardrik.Context{step: :generate} = context, next, _opts),
      do: next.(%{context | tools: offer(context.tools)})

    def call(%Wardrik.Context{step: {:tool_call, %{name: @tool} = call}} = context, _next, _opts) do
      :ok = Wardrik.Chat.Prompts.suggest_next(context, call.arguments["prompts"])
      {:ok, %{context | response: {:ok, "They'll see these with your reply."}}}
    end

    def call(context, next, _opts), do: next.(context)

    defp offer(tools) do
      if Enum.any?(tools, &(&1.name == @tool)), do: tools, else: [tool() | tools]
    end

    defp tool do
      Wardrik.Tool.new!(
        name: @tool,
        description:
          "Suggest up to four short things the person might ask you next. Call it once, " <>
            "just before your final answer.",
        schema: [prompts: [type: {:list, :string}, required: true]],
        run: fn _args, _context -> {:ok, "Shown."} end
      )
    end
  end

  setup :start_wardrik

  test "a middleware's suggestions are kept as prompts.suggested in the conversation",
       %{wardrik: wardrik, fake: fake} do
    test = self()

    Model.answer(fake, fn request ->
      send(test, {:offered, Enum.map(request["tools"] || [], &get_in(&1, ["function", "name"]))})

      if Enum.any?(request["messages"], &(&1["role"] == "tool")),
        do: answer("Drafted."),
        else: calling([call("call_1", "suggest_next_steps", %{prompts: ["Send it", "Not yet"]})])
    end)

    {:ok, _agent} =
      Wardrik.start_agent(wardrik,
        agent_id: "acme/triage",
        model: "anthropic:claude-haiku-4-5",
        middleware: [NextSteps]
      )

    scope = owner(wardrik)

    assert {:ok, %Wardrik.Reply{text: "Drafted."}} =
             Wardrik.Agent.reply(scope, "acme/triage", "Draft the email")

    assert_received {:offered, ["suggest_next_steps"]}

    {:ok, %Wardrik.Page{events: events}} = Wardrik.Agent.events(scope, "acme/triage")

    assert [%Wardrik.Event{data: %{"prompts" => ["Send it", "Not yet"]}}] =
             for(%Wardrik.Event{type: "wardrik.prompts.suggested"} = event <- events, do: event)
  end
end
