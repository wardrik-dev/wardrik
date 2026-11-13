# Approvals

> See it in action: [Tool call approvals](../notebooks/approvals-demo.livemd)

A call a policy asks about waits for a person. The calls an agent waits on are its interrupts.

## Setup

The agent calls a model, so set your Anthropic key.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.12"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer
  def authorize(_request, _opts), do: :ok
end

# Every agent works for Maria.
defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver
  def resolve(_request, _opts), do: {:ok, %Wardrik.Resolved{principal: Wardrik.principal("maria")}}
end

defmodule MyApp.Books do
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "pay_bill",
        description: "Pays a vendor's bill, in dollars.",
        schema: [vendor: [type: :string, required: true], amount: [type: :integer, required: true]],
        run: fn %{vendor: vendor, amount: amount}, _ctx -> {:ok, "Paid #{vendor} $#{amount}."} end
      )
    ]
  end
end

System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []},
    capabilities: [books: MyApp.Books]
  )

scope = Wardrik.as(MyApp.AgentRuntime, "maria")

{:ok, _agent} =
  Wardrik.Agent.define(scope, "agt_books",
    model: "anthropic:claude-haiku-4-5",
    tools: ["books"],
    policy: [ask: %{"pay_bill(amount >= 1000)" => "A bill this size needs a person."}]
  )
```

## Approve or deny one call

```elixir
{:waiting, [initech, globex]} =
  Wardrik.Agent.reply(scope, "agt_books", "Pay Initech's $9400 bill and Globex's $2100 bill.")

initech
#=> %Wardrik.Interrupt{id: "toolu_01...", agent: "agt_books", name: "pay_bill",
#=>   message: "A bill this size needs a person.", ...}

Wardrik.Agent.approve(scope, interrupt: initech, note: "Use the ops account.")
#=> {:ok, [%Wardrik.Decision{id: "toolu_01...", decision: :approved}]}

Wardrik.Agent.deny(scope, interrupt: globex, reason: "Not before the 1st.")
#=> {:ok, [%Wardrik.Decision{id: "toolu_02...", decision: :rejected}]}
```

- Decide in any order. An approved call runs at once. The model carries on when all are decided.
- The model reads a `note` beside the result, and a `reason` as the call's error.
- Each decision is recorded as Maria's.
- `Wardrik.Interrupts.list/2` lists waiting calls across every agent the scope can see.
- An interrupt names its agent and conversation. With an ID, give `agent:` and any
  `conversation:` too.

## Decide several at once

```elixir
{:waiting, [initech, globex]} =
  Wardrik.Agent.reply(scope, "agt_books", "Pay Initech's $9400 bill and Globex's $2100 bill.")

Wardrik.Agent.decide(scope,
  agent: "agt_books",
  decisions: %{
    initech.id => {:approve, "Use the ops account."},
    globex.id => {:deny, "Not before the 1st."}
  }
)
#=> {:ok, [%Wardrik.Decision{decision: :approved, ...}, %Wardrik.Decision{decision: :rejected, ...}]}
```

- Each value is `:approve`, `{:approve, note}` or `{:deny, reason}`.
- Deciding a call the agent no longer waits on returns `conflict`.
- A call waiting on a sign-in has a link: see `Wardrik.Agent.authorization/2` and
  [Credentials](credentials.md).
