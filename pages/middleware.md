# Middleware

## Setup

Paste this into a fresh IEx session. The model calls need an Anthropic key. The agent gets the
order tool from [Tools](tools.md):

```elixir
Mix.install([{:wardrik_core, "~> 0.1.0-rc.1"}])
System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _} = Supervisor.start_link(children, strategy: :rest_for_one)

defmodule MyApp.Orders do
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, orders) do
    [
      WardrikCore.Tool.new!(
        name: "order_status",
        description: "Say where an order is.",
        schema: [order_id: [type: :string, required: true]],
        run: fn %{order_id: id}, _context -> {:ok, Map.get(orders, id, "unknown")} end
      )
    ]
  end
end
```

Replace `"sk-ant-..."` with your key.

## Wrapping every call

Middleware wraps each turn, model call and tool call. It reads the step from `context.step`, then
calls `next` to carry on or answers the step itself. This one refuses the shell:

```elixir
defmodule MyApp.NoShell do
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%{step: {:tool_call, %{name: "shell"}}} = context, _next, _opts),
    do: {:ok, %{context | response: {:error, "No shell."}}}

  def call(context, next, _opts), do: next.(context)
end
```

The refusal becomes the call's answer. The model sees it as an error, and carries on.

Use middleware when every call needs the same treatment: policy, tracing, retries, a system prompt.
Like capabilities, it takes options as `{MyApp.NoShell, opts}`.

## Waiting for a person

Middleware can park a call until a person answers. This one asks before any tool runs:

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
```

The first middleware in the list runs outermost. The turn waits until you resume it with an answer
for each call:

```elixir
{:tool_calls, [{call, {:park, :approval}}]} = WardrikCore.parked(agent)
#=> {:tool_calls, [{%WardrikCore.ToolCall{name: "order_status", ...}, {:park, :approval}}]}

:ok = WardrikCore.resume(agent, %{call.id => :approve}, %{by: "user:maria"})
```

The metadata, here who answered, appears on the resumed turn's
`[:wardrik_core, :turn, :start]` event.

## Private state

Middleware can keep state with the agent, such as a count or what it spent. Store it with
`WardrikCore.Context.put_private/3`, under your own module as the key. It's saved with the agent,
so it survives restarts.

## Asking a model

When middleware needs a model's judgement on a call, `WardrikCore.evaluate/2` asks an evaluation
model. `WardrikCore.generate/1` calls the agent's own model.
