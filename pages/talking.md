# Talk to agents

Each function here sends an agent a message and follows the run that answers it. Each takes the
scope, the agent by its ID or as a `%Wardrik.Agent{}`, and what to say.

## Stream an answer

`Wardrik.Agent.stream/4` returns the answer's text as it's written, and ends with the run:

```elixir
scope
|> Wardrik.Agent.stream("acme/triage", "What's on fire?")
|> Enum.each(&IO.write/1)
```

Raises `Wardrik.Error` if the scope can't reach the agent. Takes `:timeout`, the longest wait
between chunks. Ten minutes unless set.

## Wait for a reply

`Wardrik.Agent.reply/4` returns the answer once the run ends:

```elixir
case Wardrik.Agent.reply(scope, "acme/triage", "What's on fire?") do
  {:ok, %Wardrik.Reply{text: text}} -> text
  {:waiting, interrupts} -> ask_someone(interrupts)
  {:error, %Wardrik.Error{message: message}} -> message
end
```

  * `{:ok, %Wardrik.Reply{}}` - the run finished, as
    `%Wardrik.Reply{message: "msg_Xq3f...", run: "0af76519...", text: "Nothing's on fire."}`.
  * `{:waiting, interrupts}` - a policy asked a person before a call could run. See
    [Approvals](approvals.md).
  * `{:error, %Wardrik.Error{}}` - the agent can't be reached, or the run failed.

## Send the answer to a process

From a LiveView or a GenServer, pass `to:`. The answer arrives as messages:

```elixir
{:ok, ref} = Wardrik.Agent.stream(scope, agent, "Summarise the incident.", to: self())

def handle_info({Wardrik, _ref, {:text, chunk}}, socket),
  do: {:noreply, update(socket, :answer, &(&1 <> chunk))}

def handle_info({Wardrik, _ref, {:done, %Wardrik.Reply{}}}, socket), do: {:noreply, socket}
```

Each message is `{Wardrik, ref, item}`. The items are `{:text, chunk}`, then one of
`{:done, %Wardrik.Reply{}}`, `{:waiting, interrupts}` or `{:failed, reason}`.

## Just send it

`Wardrik.Agent.ask/3` sends the message and returns at once, with the cursor the answer comes
after. Use it to follow the answer yourself:

```elixir
Wardrik.Agent.ask(scope, "acme/triage", "Hi")
#=> {:ok, %Wardrik.Message{id: "msg_Xq3f...", cursor: "eyJhY21lL3RyaWFnZSI6NDF9"}}
```

It takes text, or `content:`, `parts:` and an `id:` of your own.
