# Approvals

A call a policy asks about waits for a person to approve or deny it. The calls an agent waits on
are its interrupts.

> See it in action: [A person in the loop](../notebooks/approvals-demo.livemd)

## Setup

In a fresh IEx session, define a tool, start Wardrik with it, and define an agent whose policy asks
about large bills. The agent calls a model, so set your Anthropic key first:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.1"}])

System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

defmodule MyApp.Books do
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "pay_bill",
        description: "Pays a vendor's bill, in dollars.",
        schema: [vendor: [type: :string, required: true], amount: [type: :integer, required: true]],
        run: fn %{vendor: vendor, amount: amount}, _context -> {:ok, "Paid #{vendor} $#{amount}."} end
      )
    ]
  end
end

{:ok, _} = Wardrik.start_link(name: MyApp.AgentRuntime, capabilities: [books: MyApp.Books])
scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria", roles: [:owner], resources: ["acme/@maria/*"])

{:ok, _agent} =
  Wardrik.Agent.define(scope, "acme/@maria/books",
    model: "anthropic:claude-haiku-4-5",
    tools: ["books"],
    policy: [ask: %{"pay_bill(amount >= 1000)" => "A bill this size needs a person."}]
  )
```

## Decide one call at a time

Ask for two large payments. The run stops and returns the calls it waits on:

```elixir
{:waiting, [initech, globex]} =
  Wardrik.Agent.reply(scope, "acme/@maria/books", "Pay Initech's $9400 bill and Globex's $2100 bill.")

initech
#=> %Wardrik.Interrupt{id: "toolu_01...", agent_id: "acme/@maria/books", reason: :tool_approval,
#=>   name: "pay_bill", message: "A bill this size needs a person.", ...}
```

`Wardrik.Interrupts.list/2` returns the calls waiting across every agent the scope can see.

Approve one, with a note, and deny the other, with a reason:

```elixir
Wardrik.Agent.approve(scope, "acme/@maria/books", initech.id, note: "Pay it from the ops account.")
#=> {:ok, [%Wardrik.Decision{id: "toolu_01...", decision: :approved}]}

Wardrik.Agent.deny(scope, "acme/@maria/books", globex.id, reason: "Not before the 1st.")
#=> {:ok, [%Wardrik.Decision{id: "toolu_02...", decision: :rejected}]}
```

  * Each waiting call is decided on its own, in any order. An approved call runs straight away,
    and the model reads the results once all are decided.
  * An approval runs the call as the model wrote it. A `note` reaches the model beside the result.
  * A denial reaches the model as an error, with your `reason`.
  * Each decision is recorded as the scope's principal's.

## Decide several at once

`Wardrik.Agent.decide/3` takes a map of call IDs to decisions:

```elixir
{:waiting, [initech, globex]} =
  Wardrik.Agent.reply(scope, "acme/@maria/books", "Pay Initech's $9400 bill and Globex's $2100 bill.")

Wardrik.Agent.decide(scope, "acme/@maria/books", %{
  initech.id => {:approve, "Pay it from the ops account."},
  globex.id => {:deny, "Not before the 1st."}
})
#=> {:ok,
#=>  [
#=>    %Wardrik.Decision{id: "toolu_03...", decision: :approved},
#=>    %Wardrik.Decision{id: "toolu_04...", decision: :rejected}
#=>  ]}
```

Each value is `:approve`, `{:approve, note}` or `{:deny, reason}`.

Deciding a call the agent doesn't wait on, or no longer waits on, returns a `conflict` error:

```elixir
Wardrik.Agent.approve(scope, "acme/@maria/books", initech.id)
#=> {:error, %Wardrik.Error{type: :conflict, ...}}
```

When an agent waits for someone to sign in, `Wardrik.Agent.authorization/4` returns the link; see
[Credentials](credentials.md).
