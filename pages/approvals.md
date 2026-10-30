# Approvals

A call a policy asks about waits for a person to approve or deny it. The calls an agent waits on
are its interrupts:

```elixir
Wardrik.Interrupts.list(scope)
#=> {:ok,
#=>  [
#=>    %Wardrik.Interrupt{
#=>      id: "call_1",
#=>      agent_id: "acme/books",
#=>      reason: :tool_approval,
#=>      message: "A bill this size needs a person.",
#=>      name: "books__pay_bill",
#=>      tool_call_id: "call_1"
#=>    }
#=>  ]}

Wardrik.Agent.approve(scope, "acme/books", "call_1", note: "Pay it from the ops account.")
Wardrik.Agent.deny(scope, "acme/books", "call_2", reason: "Not before the 1st.")
```

  * Each waiting call is decided on its own, in any order. The agent carries on once all are
    decided.
  * An approval runs the call as the model wrote it. A `note` reaches the model beside the result.
  * A denial reaches the model as an error, with your `reason`.
  * Each decision is recorded as the scope's principal's.

To decide several calls at once, use `Wardrik.Agent.decide/3`, keyed by call ID:

```elixir
Wardrik.Agent.decide(scope, "acme/books", %{
  "call_1" => {:approve, "Pay it from the ops account."},
  "call_2" => {:deny, "Not before the 1st."}
})
#=> {:ok,
#=>  [
#=>    %Wardrik.Decision{id: "call_1", decision: :approved},
#=>    %Wardrik.Decision{id: "call_2", decision: :rejected}
#=>  ]}
```

Each value is `:approve`, `{:approve, note}` or `{:deny, reason}`.

Deciding a call the agent doesn't wait on, or no longer waits on, returns `conflict`.

When an agent waits for someone to sign in, `Wardrik.Agent.authorization/4` returns the link; see
[Credentials](credentials.md).
