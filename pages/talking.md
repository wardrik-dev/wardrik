# Talk to agents

Every way to talk to an agent sends it a message and follows the run that answers it. Each takes
the scope, the agent by its id or as a `%Wardrik.Agent{}`, and what to say.

## Stream an answer

`Wardrik.Agent.stream/4` returns the answer's text as it's written, ending with the run:

```elixir
scope
|> Wardrik.Agent.stream("acme/triage", "What's on fire?")
|> Enum.each(&IO.write/1)
```

It raises a `Wardrik.Error` where the scope can't reach the agent.

## Wait for a reply

```elixir
case Wardrik.Agent.reply(scope, "acme/triage", "What's on fire?") do
  {:ok, %Wardrik.Reply{text: text}} -> text
  {:waiting, interrupts} -> ask_someone(interrupts)
  {:error, %Wardrik.Error{message: message}} -> message
end
```

`{:waiting, interrupts}` means a policy asked a person before a call could run; see
[Approvals](approvals.md).

## Hand the answer to a process

From a LiveView or a GenServer, give `to:`, and the answer comes as messages:

```elixir
{:ok, ref} = Wardrik.Agent.stream(scope, agent, "Summarise the incident.", to: self())

def handle_info({Wardrik, ref, {:text, chunk}}, socket), do: {:noreply, stream_insert(socket, chunk)}
def handle_info({Wardrik, ref, {:done, %Wardrik.Reply{}}}, socket), do: {:noreply, socket}
```

What comes is `{:text, chunk}`, then one of `{:done, %Wardrik.Reply{}}`, `{:waiting, interrupts}`
or `{:failed, reason}`.

## Just send it

`Wardrik.Agent.ask/3` sends the message and answers at once, with the cursor the answer comes after,
for following it yourself:

```elixir
{:ok, %Wardrik.Message{id: id, cursor: cursor}} = Wardrik.Agent.ask(scope, "acme/triage", "Hi")
```

It takes text, or `content:`, `parts:` and your own `id:`.
