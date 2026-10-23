# Approvals

A call a policy asks about waits on a person, who approves or denies it. What an agent waits on are
its interrupts:

```elixir
{:ok, [%Wardrik.Interrupt{agent_id: "acme/books", id: "call_1", message: message} | _rest]} =
  Wardrik.Interrupts.list(scope)

Wardrik.Agent.approve(scope, "acme/books", "call_1", note: "Pay it from the ops account.")
Wardrik.Agent.deny(scope, "acme/books", "call_2", reason: "Not before the 1st.")
```

Each waiting call is decided on its own, in any order, and the agent carries on once all are
decided. A denial reaches the model as an error with your reason. An approval runs the call as the
model wrote it, and a note reaches the model beside the result. Each decision is recorded as the
scope's principal's.

To decide several calls at once, reach for `Wardrik.Agent.decide/3`, with each call's decision by
its id:

```elixir
{:ok, [%Wardrik.Decision{decision: :approved}, %Wardrik.Decision{decision: :rejected}]} =
  Wardrik.Agent.decide(scope, "acme/books", %{
    "call_1" => {:approve, "Pay it from the ops account."},
    "call_2" => {:deny, "Not before the 1st."}
  })
```

Deciding a call the agent doesn't wait on, or no longer does, answers `conflict`.

Where an agent waits on someone to sign in, `Wardrik.Agent.authorization/4` gives the link.
