# Wardrik

**Agents, governed.**

Run agents with rules the model can't rewrite, approvals from the people you choose, budgets that cap what they spend, and a record of everything they did.

## Install

```elixir
def deps do
  [
    {:wardrik, "~> 0.1.0-rc.1"}
  ]
end
```

## Start it

Define a module that uses `Wardrik`, configure it, and add it to your supervision tree:

```elixir
defmodule MyApp.Runtime do
  use Wardrik, otp_app: :my_app
end

# config/runtime.exs
config :my_app, MyApp.Runtime,
  store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"},
  policy: [deny: ["shell/*"]]

# application.ex
children = [MyApp.Runtime]
```

Then act as someone, and talk to agents:

```elixir
scope = MyApp.Runtime.as("acme/@maria", roles: [:owner], resources: ["acme/@maria/*"])

{:ok, notes_agent} =
  Wardrik.Agent.define(scope, "acme/@maria/assistant",
    model: "anthropic:claude-haiku-4-5",
    instructions: "You keep Maria's notes.",
    policy: [budget: [usd: 1.00, per: :day]]
  )

Wardrik.Agent.reply(scope, notes_agent, "What did I note yesterday?")
#=> {:ok, %Wardrik.Reply{message: "msg_Xq3f...", run: "0af76519...", text: "You noted the Q3 numbers..."}}
```

Or Stream the results:

```elixir

scope
|> Wardrik.Agent.stream(notes_agent, "Summarize yesterday's notes.")
|> Enum.each(&IO.write/1)
```

## Guides

- [Run Wardrik](pages/running-wardrik.md): the instance module, its options, where agents are kept,
  and its nodes.
- [Talk to agents](pages/talking.md): asking, streaming answers, and replies.
- [Define agents](pages/definitions.md): what agents are and may do, as data, and how they sleep and
  wake.
- [Trigger agents](pages/triggers.md): asking agents on a clock, from a feed, or from a webhook.
- [Policies](pages/policies.md): rules the model can't rewrite, held at once by the deployment and
  each agent, and budgets.
- [Who may do what](pages/access.md): scopes, grants and roles, API tokens, and your own
  authorizer.
- [Operations](pages/operations.md): every operation as a function, taking and answering structs.
- [Approvals](pages/approvals.md): deciding the calls agents wait on.
- [MCP servers](pages/servers.md): the servers agents call, those Wardrik starts with and those an
  org or person adds as it runs.
- [Credentials and sign-ins](pages/credentials.md): sealed credentials, and people signing in to
  give agents their accounts.
- [Events and the audit](pages/events.md): following what agents do into your app, and what people
  did.
- [Over HTTP](https://hexdocs.pm/wardrik_http): every operation as a route, with `wardrik_http`.

## License

Apache-2.0
