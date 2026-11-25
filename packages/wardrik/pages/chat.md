# Chat apps

Talk to agents from chat apps, such as Slack. `Wardrik.Chat` holds what every chat adapter
shares: rooms, threads, replies and approvals.

## Set up

Start with a [Wardrik runtime](running-wardrik.md) named `MyApp.AgentRuntime`.
The following fragments belong in an existing app.

In `config/runtime.exs`, after implementing `MyApp.ChatMembers` below:

```elixir
config :my_app, MyApp.AgentRuntime,
  channels: [
    slack:
      {WardrikSlack,
       token: System.fetch_env!("SLACK_BOT_TOKEN"),
       signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
       owner: "acme",
       identities: {MyApp.ChatMembers, []}}
  ]
```

Implement `identify/2` to map chat members to your app's users. Return an error to reject a member.

```elixir
defmodule MyApp.ChatMembers do
  @behaviour Wardrik.Chat.Identities

  @impl true
  def identify(request, _opts) do
    case MyApp.Accounts.by_chat(request.channel, request.workspace, request.member) do
      %MyApp.User{} = user -> {:ok, Wardrik.principal(user.id)}
      nil -> {:error, "Link your Slack account in MyApp first."}
    end
  end
end
```

Serve the chat app's requests with `Wardrik.HTTP`. It answers `POST /v1/channels/slack/...`.
Then list the channel in an agent's definition:

```elixir
scope = MyApp.AgentRuntime.as("maria")

Wardrik.Agent.define(scope, "agt_01JF8X5RQ2",
  model: "anthropic:claude-haiku-4-5",
  channels: ["slack"]
)
```

## In the chat

- Invite the bot into a room. If one agent is offered, it answers there. With several, someone picks.
- Mention the bot. The agent answers in a thread.
- Reply in the thread. No mention needed.
- Each thread is its own conversation, such as `"slack.T0123.C024BE91L.1696.1234"`.
- Calls the agent waits on are posted in the thread to approve or deny.

## Next steps

A run can suggest what to ask next. The chat app shows them with the reply: Slack's Messages tab
takes them as its prompts, and a channel shows them as buttons under the reply. A press asks the
agent that text, as whoever pressed it.

Wardrik keeps whatever `Wardrik.Chat.Prompts.suggest_next/2` is given as
`wardrik.prompts.suggested` in the conversation's log; the last before the reply is shown. Which
steps to suggest is up to your own `Wardrik.Middleware`. This one offers the model a tool, and
answers its calls itself:

```elixir
defmodule MyApp.NextSteps do
  @behaviour Wardrik.Middleware

  @tool "suggest_next_steps"

  @impl true
  def call(%Wardrik.Context{step: :generate} = context, next, _opts),
    do: next.(%{context | tools: offer(context.tools)})

  def call(%Wardrik.Context{step: {:tool_call, %{name: @tool} = call}} = context, _next, _opts) do
    :ok = Wardrik.Chat.Prompts.suggest_next(context, call.arguments["prompts"])
    {:ok, %{context | response: {:ok, "They'll see these with your reply."}}}
  end

  def call(context, next, _opts), do: next.(context)

  defp offer(tools) do
    if Enum.any?(tools, &(&1.name == @tool)), do: tools, else: [tool() | tools]
  end

  defp tool do
    Wardrik.Tool.new!(
      name: @tool,
      description:
        "Suggest up to four short things the person might ask you next. Call it once, " <>
          "just before your final answer.",
      schema: [prompts: [type: {:list, :string}, required: true]],
      run: fn _args, _context -> {:ok, "Shown."} end
    )
  end
end
```

Give it to an agent as `middleware: [MyApp.NextSteps]`. A policy decides its calls as any
other's, so allow `suggest_next_steps` by name.

## Access

Your authorizer decides what chat members may read, ask and decide. Requests from a chat have
`actor: {:channel, "slack"}`. Their `context` has `:installation`, and `:asked_by` when deciding.

```elixir
# Whoever asked decides their own calls.
def authorize(%{actor: {:channel, _name}, action: "agent.decide"} = request, _opts) do
  if request.context[:asked_by] == request.principal.id, do: :ok, else: {:error, :forbidden}
end
```

## Many workspaces

Alternative channel option fragments: replace `token:` and `owner:` with one of these options:

```elixir
# requires Wardrik's :vault_keys
[installations: :stored]

# implements Wardrik.Channel.Installations
[installations: {MyApp.ChatInstallations, []}]
```

## Notices

`notify: "slack:#ops"` in a definition posts in `#ops`. The workspace is the one your resolver gives
the agent, as `%Wardrik.Resolved{channels: %{"slack" => "T0123"}}`.
