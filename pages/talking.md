# Talk to agents

> See it in action: [Wardrik in ten minutes](../notebooks/tour-demo.livemd)

## Setup

Answers come from the model, so set your Anthropic key.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.5"}])

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

System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []}
  )

scope = Wardrik.as(MyApp.AgentRuntime, "maria")

{:ok, agent} =
  Wardrik.Agent.define(scope, "agt_assistant",
    model: "anthropic:claude-haiku-4-5",
    instructions: "You keep Maria's notes."
  )
```

Each function takes the agent by ID or as a `%Wardrik.Agent{}`.

## Stream

```elixir
scope
|> Wardrik.Agent.stream(agent, "What's on today?")
|> Enum.each(&IO.write/1)
```

- Yields the text as it's written.
- Raises `Wardrik.Error` if the scope can't reach the agent.
- `:timeout` is the longest wait between chunks, in milliseconds. Ten minutes unless set.

## Reply

```elixir
Wardrik.Agent.reply(scope, "agt_assistant", "What's on today?")
#=> {:ok, %Wardrik.Reply{message: "msg_Xq3f...", run: "0af76519...", text: "Nothing yet."}}
```

- `{:ok, %Wardrik.Reply{}}` - the run finished.
- `{:waiting, interrupts}` - a call waits for a person. See [Approvals](approvals.md).
- `{:error, %Wardrik.Error{}}` - the agent can't be reached, or the run failed.

## Send to a process

With `to:`, the answer arrives as messages, for a LiveView or GenServer:

```elixir
{:ok, ref} = Wardrik.Agent.stream(scope, agent, "Summarise my week.", to: self())
flush()
#=> {Wardrik, #Reference<...>, {:text, "Nothing "}}
#=> {Wardrik, #Reference<...>, {:text, "much."}}
#=> {Wardrik, #Reference<...>, {:done, %Wardrik.Reply{text: "Nothing much.", ...}}}
```

The last item is `{:done, reply}`, `{:waiting, interrupts}` or `{:failed, reason}`.

## Send and return

```elixir
Wardrik.Agent.ask(scope, agent, "Hi")
#=> {:ok, %Wardrik.Message{id: "msg_Xq3f...", cursor: "W1siYWd0X2Fzc2lzdGFudCIsbnVsbCwxNl1d"}}

Wardrik.Agent.ask(scope, agent, content: "Hi again", id: "msg_hi-again")
#=> {:ok, %Wardrik.Message{id: "msg_hi-again", cursor: "..."}}
```

The answer comes after `cursor`. Follow it with [events](events.md).
