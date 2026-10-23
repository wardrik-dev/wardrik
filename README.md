# Wardrik

**Agents, governed.**

Run agents in your Elixir app with rules the model can't rewrite, approvals from the people you
choose, budgets that cap what they spend, and a record of everything they did.

## Install

```elixir
def deps do
  [
    {:wardrik, "~> 0.1"}
  ]
end
```

## Start it

Describe your Wardrik, add it to your supervision tree, and start an agent held to a policy:

```elixir
wardrik = Wardrik.new(name: MyApp.Wardrik, data_dir: "/var/lib/my_app", policy: [deny: ["shell/*"]])

children = [{Wardrik, wardrik}]

Wardrik.start_agent(wardrik,
  agent_id: "acme/books",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [MyApp.Books],
  policy: [ask: ["books/pay_bill(amount >= 1000)"], budget: [usd: 5.00, per: :day]]
)
```

Then ask it something, as a person allowed to:

```elixir
owner = Wardrik.Statement.new(roles: [:owner], resources: ["*"])
scope = Wardrik.as(wardrik, "acme/@maria", [owner])

{:ok, %Wardrik.Message{}} = Wardrik.Agent.ask(scope, "acme/books", "Which bills are due this week?")
```

## Guides

- [Run Wardrik](pages/running-wardrik.md): options, where agents are kept, and starting agents.
- [Define agents](pages/definitions.md): what agents are and may do, as data, and how they sleep and
  wake.
- [Trigger agents](pages/triggers.md): asking agents on a clock, from a feed, or from a webhook.
- [Policies](pages/policies.md): rules the model can't rewrite, held at once by the deployment and
  each agent, and budgets.
- [Who may do what](pages/access.md): scopes, statements and roles, and your own authorizer.
- [Operations](pages/operations.md): asking, reading and cancelling, as functions or by ID.
- [Approvals](pages/approvals.md): deciding the calls agents wait on.
- [MCP servers](pages/servers.md): the servers agents call, those Wardrik starts with and those an
  org or person adds as it runs.
- [Credentials and sign-ins](pages/credentials.md): sealed credentials, and people signing in to
  give agents their accounts.
- [Events and the audit](pages/events.md): following what agents do, and what people did.

## License

Apache-2.0
