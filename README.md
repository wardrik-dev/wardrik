# Wardrik

Runs agents with tool policies, approval checks, spending limits, and event logs.

## Start in IEx

Set `ANTHROPIC_API_KEY` before starting `iex`.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.9"}])

defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer
  @impl true
  def authorize(_request, _opts), do: :ok
end

defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver
  @impl true
  def resolve(_request, _opts) do
    {:ok, %Wardrik.Resolved{principal: Wardrik.principal("maria")}}
  end
end

defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app
end

{:ok, _runtime} =
  MyApp.AgentRuntime.start_link(
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []}
  )

scope = MyApp.AgentRuntime.as("maria")

{:ok, agent} =
  Wardrik.Agent.define(scope, "agt_assistant",
    model: "anthropic:claude-haiku-4-5",
    instructions: "Summarize the user's notes.",
    policy: [budget: [usd: 1.00, per: :day]]
  )

Wardrik.Agent.reply(scope, agent, "Summarize this note: The release is scheduled for Friday.")
```

- The example authorizer permits every operation. Implement access checks for your app.
- The example stores data in memory. See [Run Wardrik](pages/running-wardrik.md) for persistent storage and application configuration.
- See `Wardrik.start_link/1` for runtime options.

## Guides

- [Run Wardrik](pages/running-wardrik.md)
- [Send messages](pages/talking.md)
- [Define agents](pages/definitions.md)
- [Configure triggers](pages/triggers.md)
- [Apply policies](pages/policies.md)
- [Authorize operations](pages/access.md)
- [Call operations](pages/operations.md)
- [Approve tool calls](pages/approvals.md)
- [Connect MCP servers](pages/servers.md)
- [Store credentials and connect accounts](pages/credentials.md)
- [Read events and audit records](pages/events.md)
- [Serve HTTP requests](https://hexdocs.pm/wardrik_http)

## Livebook examples

Start with [Wardrik in ten minutes](notebooks/tour-demo.livemd).

- [Tool policies](notebooks/policies-demo.livemd)
- [Tool call approvals](notebooks/approvals-demo.livemd)
- [Agent tools](notebooks/tools-demo.livemd)
- [Spending limits](notebooks/budgets-demo.livemd)
- [Crash recovery](notebooks/durability-demo.livemd)
- [Scheduled runs and webhooks](notebooks/triggers-demo.livemd)
- [Event logs](notebooks/events-demo.livemd)
- [Operation authorization](notebooks/access-demo.livemd)

## License

Apache-2.0
