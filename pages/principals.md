# Who sent a message

Tell the agent who sent each message. Your tools and middleware can then act for that person.

Run the [setup](running-agents.md#setup) in IEx first.

## Send a message as someone

```elixir
alias WardrikCore.Principal

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    principal: %Principal{id: "agent:support"}
  )

maria = %Principal{id: "user:maria", attributes: %{team: "billing"}}
:ok = WardrikCore.ask(agent, "Open an issue for the login bug.", %{principal: maria})

[asked | _] = WardrikCore.history(agent)
asked.metadata.principal
#=> %WardrikCore.Principal{id: "user:maria", attributes: %{team: "billing"}}
```

- `:principal` on `start_agent/2` is the agent's own identity, like a service account.
- `WardrikCore.Context.acting_for/1` returns who the turn acts for: the sender, or else the agent.
- A turn answers messages from one sender only, so two people's requests never mix.
- Each step's span records the sender's ID as `"enduser.id"`.
- IDs and `attributes` are your app's. Wardrik passes them on and never reads them.
