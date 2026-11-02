# Middleware

Middleware wraps each turn, model call and tool call.

Run the [setup](running-agents.md#setup) and define `MyApp.Orders` from [Tools](tools.md) first.

## Refuse a call

```elixir
defmodule MyApp.NoShell do
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%{step: {:tool_call, %{name: "shell"}}} = context, _next, _opts),
    do: {:ok, %{context | response: {:error, "No shell."}}}

  def call(context, next, _opts), do: next.(context)
end
```

- `context.step` says which step runs.
- Call `next` to carry on, or answer the step yourself.
- The model sees the refusal as the call's error, and carries on.

## Wait for a person

```elixir
defmodule MyApp.Approve do
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%{step: {:tool_call, call}} = context, next, _opts) do
    case answer(context, call) do
      :approve -> next.(context)
      {:deny, reason} -> {:ok, %{context | response: {:error, reason}}}
      nil -> {:park, :approval, context}
    end
  end

  def call(context, next, _opts), do: next.(context)

  defp answer(%{resume: %{input: answers}}, call), do: Map.get(answers, call.id)
  defp answer(_context, _call), do: nil
end

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    capabilities: [{MyApp.Orders, %{"1001" => "shipped"}}],
    middleware: [MyApp.NoShell, MyApp.Approve]
  )

:ok = WardrikCore.ask(agent, "Where is order 1001?")

{:tool_calls, [{call, {:park, :approval}}]} = WardrikCore.parked(agent)
:ok = WardrikCore.resume(agent, %{call.id => :approve}, %{by: "user:maria"})
```

- The first middleware in the list runs outermost.
- The third argument to `resume/3` shows up on the turn's `[:wardrik_core, :turn, :start]` event.

## More

- Keep state across restarts with `WardrikCore.Context.put_private/3`, keyed by your module.
- Ask a model about a call with `WardrikCore.evaluate/2`.
- Call the agent's own model with `WardrikCore.generate/1`.
