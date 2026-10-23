# Who may do what

Every operation runs in a scope: who acts, and what they're allowed.

## Scopes and statements

Statements allow actions on resources, as IAM's do. The agent `acme/books` is the resource
`acme/agent/books`, and `acme/@jon/notes` is `acme/@jon/agent/notes`:

```elixir
scope =
  Wardrik.as(wardrik, "acme/@maria", [
    Wardrik.Statement.new(roles: [:reader, :messenger], resources: ["acme/agent/*"]),
    Wardrik.Statement.new(roles: [:owner], resources: ["acme/@maria/*"])
  ])
```

| Role | Actions |
| --- | --- |
| `:reader` | `agent.read`, `agent.events` |
| `:messenger` | `agent.ask`, `agent.cancel`, `agent.clear` |
| `:approver` | `agent.decide` |
| `:definer` | `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget` |
| `:owner` | every action |

A principal is who acts, by id, or a `WardrikCore.Principal` with attributes your authorizer
reads. Notice that an agent no statement reaches is one the scope can't see: operations on it answer
`not_found`, and lists leave it out. An agent a statement reaches without the action answers
`forbidden`.

## Write your own authorizer

Reach for this when your app already decides who may do what. Implement `Wardrik.Authorizer`, and
give it to Wardrik:

```elixir
defmodule MyApp.Authorizer do
  @behaviour Wardrik.Authorizer

  @impl true
  def authorize(_config, %Wardrik.Scope{principal: principal}, action, resource) do
    MyApp.Permissions.check(principal.id, action, resource)
  end
end

Wardrik.new(name: MyApp.Wardrik, data_dir: "/var/lib/my_app", authorizer: {MyApp.Authorizer, []})
```

It answers `:ok`, `{:error, :not_found}` where the scope can't see the resource, or
`{:error, :forbidden}` where it can without the action. Your grants are in the scope's `grants`, as
you gave them to `Wardrik.as/3`.
