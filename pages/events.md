# Events and the audit

Every agent's events are kept, to read back or follow, and everything people did through Wardrik is
in the audit.

## Follow events

Read events from a cursor, or follow them. Operations that can be streamed have a `stream_`
function, which reads on and then follows, as `{event, cursor}`:

```elixir
{:ok, cursor} = Wardrik.Events.head(scope)
{:ok, stream} = Wardrik.Events.stream_list(scope, after: cursor, resources: ["acme/*"])

for {event, cursor} <- stream do
  MyApp.show(event, cursor)
end
```

Notice that a scope only ever sees the events of the agents it can see, and a cursor only names
those agents.

## The audit

Everything people did through Wardrik, for the deployment:

```elixir
{:ok, %Wardrik.Page{events: changes, next: next}} = Wardrik.Audit.list(scope, limit: 50)
```
