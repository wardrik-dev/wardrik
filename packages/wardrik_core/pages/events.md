# Events

Every event an agent emits goes to `:telemetry` and to the agent's events module.

Run the [setup](running-agents.md#setup) in IEx first.

## An events module

```elixir
defmodule MyApp.Events do
  @behaviour WardrikCore.Events

  @impl true
  def handle_event(%WardrikCore.Event{name: name}, _opts), do: IO.inspect(name)
end

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    events: {MyApp.Events, []}
  )
# [:wardrik_core, :agent, :start]

:ok = WardrikCore.ask(agent, "What's on fire?")
# [:wardrik_core, :message, :queued]
# [:wardrik_core, :turn, :start]
# [:wardrik_core, :step, :start]
# [:wardrik_core, :message, :delta]
# ...
# [:wardrik_core, :turn, :stop]
```

- In an app, send events on to clients, such as with `Phoenix.PubSub.broadcast/3`.
- `[:wardrik_core, :message, :delta]` streams the model's text as it writes.
- It runs in the agent's process. Store or send the event, and return.
- See `WardrikCore.Telemetry` for every event.

## Your own events

```elixir
WardrikCore.Event.emit({MyApp.Events, []}, [:my_app, :refused], %{}, %{agent_id: "support"})
# [:my_app, :refused]
```

From middleware or a tool, pass the context instead. The event then goes to that agent's events
module.
