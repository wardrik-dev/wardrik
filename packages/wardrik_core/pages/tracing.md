# Tracing

A turn is a trace. Each model call and tool call is a span beneath it, as in OpenTelemetry.

Run the [setup](running-agents.md#setup) in IEx first.

## Attributes and measurements

Middleware adds them to the step it runs in:

```elixir
defmodule MyApp.Trace do
  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context

  @impl true
  def call(%Context{step: :generate} = context, next, _opts) do
    context
    |> Context.attribute("app.tenant", "acme")
    |> Context.measure(:model_calls, 1)
    |> next.()
  end

  def call(context, next, _opts), do: next.(context)
end

:telemetry.attach(
  "print-steps",
  [:wardrik_core, :step, :stop],
  fn _name, measurements, metadata, _config ->
    IO.inspect({metadata.step, metadata.attributes, Map.delete(measurements, :duration)})
  end,
  nil
)

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    middleware: [MyApp.Trace]
  )

:ok = WardrikCore.ask(agent, "What's on fire?")
# {:generate, %{"app.tenant" => "acme", ...}, %{model_calls: 1, input_tokens: 12, output_tokens: 48, usd: 0.000252}}
# {:turn, %{...}, %{model_calls: 1, input_tokens: 12, output_tokens: 48, usd: 0.000252}}
```

- Each step reports them on `[:wardrik_core, :step, :stop]`.
- Measurements add up over the turn.
- Every model call measures `input_tokens`, `output_tokens`, and `usd` when the model has a price.

## Spans

```elixir
:telemetry.attach(
  "print-traceparent",
  [:wardrik_core, :step, :stop],
  fn _name, _measurements, %{span: span}, _config ->
    IO.puts(WardrikCore.Span.traceparent(span))
  end,
  nil
)

:ok = WardrikCore.ask(agent, "And now?")
# 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

- `WardrikCore.Span.traceparent/1` gives a W3C `traceparent` header for calls to other services.
- A turn keeps its trace through a wait or a restart.
