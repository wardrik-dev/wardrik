# Talk to agents

Each function here sends an agent a message and follows the run that answers it. Each takes a
scope, the agent by its ID or as a `%Wardrik.Agent{}`, and what to say.

> See it in action: [Wardrik in ten minutes](../notebooks/tour.livemd)

## Setup

In a fresh IEx session, start Wardrik, act as Maria, and define her assistant. Answers come from
the model, so set your Anthropic key in place of `"sk-ant-..."`:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.1"}])
System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

{:ok, _} = Wardrik.start_link(name: MyApp.AgentRuntime)
scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria", roles: [:owner], resources: ["acme/@maria/*"])

{:ok, agent} =
  Wardrik.Agent.define(scope, "acme/@maria/assistant",
    model: "anthropic:claude-haiku-4-5",
    instructions: "You keep Maria's notes."
  )
```

## Stream an answer

`Wardrik.Agent.stream/4` returns the answer's text as it's written, and ends with the run:

```elixir
scope
|> Wardrik.Agent.stream(agent, "What's on today?")
|> Enum.each(&IO.write/1)
```

Raises `Wardrik.Error` if the scope can't reach the agent. Takes `:timeout`, the longest wait
between chunks, in milliseconds. Ten minutes unless set.

## Wait for a reply

`Wardrik.Agent.reply/4` returns the answer once the run ends:

```elixir
Wardrik.Agent.reply(scope, "acme/@maria/assistant", "What's on today?")
#=> {:ok, %Wardrik.Reply{message: "msg_Xq3f...", run: "0af76519...", text: "Nothing yet."}}
```

  * `{:ok, %Wardrik.Reply{}}` - the run finished.
  * `{:waiting, interrupts}` - a policy asked a person before a call could run. See
    [Approvals](approvals.md).
  * `{:error, %Wardrik.Error{}}` - the agent can't be reached, or the run failed.

## Send the answer to a process

Pass `to:` and the answer arrives as messages, as a LiveView or a GenServer wants it:

```elixir
{:ok, ref} = Wardrik.Agent.stream(scope, agent, "Summarise my week.", to: self())
flush()
#=> {Wardrik, #Reference<...>, {:text, "Nothing "}}
#=> {Wardrik, #Reference<...>, {:text, "much."}}
#=> {Wardrik, #Reference<...>, {:done, %Wardrik.Reply{text: "Nothing much.", ...}}}
```

Each message is `{Wardrik, ref, item}`. The items are `{:text, chunk}`, then one of
`{:done, %Wardrik.Reply{}}`, `{:waiting, interrupts}` or `{:failed, reason}`. Match them in
`handle_info/2`. In IEx, run `flush()` again if the answer hasn't ended.

## Just send it

`Wardrik.Agent.ask/3` sends the message and returns at once, with the cursor the answer comes
after. Use it to follow the answer yourself:

```elixir
Wardrik.Agent.ask(scope, agent, "Hi")
#=> {:ok, %Wardrik.Message{id: "msg_Xq3f...", cursor: "eyJhY21lL0BtYXJpYS9hc3Npc3RhbnQiOjE2fQ"}}
```

It takes text, or `content:`, `parts:` and an `id:` of your own:

```elixir
Wardrik.Agent.ask(scope, agent, content: "Hi again", id: "msg_hi-again")
#=> {:ok, %Wardrik.Message{id: "msg_hi-again", cursor: "..."}}
```
