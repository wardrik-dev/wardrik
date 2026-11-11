# Run agents

## Setup

Paste this into IEx, with your Anthropic key:

```elixir
Mix.install([{:wardrik_core, "~> 0.1.0-rc.5"}])
System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _} = Supervisor.start_link(children, strategy: :rest_for_one)
```

In an app, put the two children in your supervision tree.

## Start an agent

```elixir
{:ok, agent} = WardrikCore.start_agent(agent_id: "support", model: "anthropic:claude-haiku-4-5")
:ok = WardrikCore.ask(agent, "What's on fire?")

WardrikCore.history(agent)
#=> [#Message<:user text>, #Message<:assistant text>]
```

- `ask/3` returns once the message is stored. The agent answers in its own process.
- Agent IDs are your app's. Wardrik doesn't read them.

## Conversations

A conversation runs on the agent's options, with its own history:

```elixir
{:ok, thread} =
  WardrikCore.start_agent(
    agent_id: "support",
    conversation: "C1",
    model: "anthropic:claude-haiku-4-5"
  )

WardrikCore.whereis("support")
WardrikCore.whereis({"support", "C1"})
```

`"support"` alone means the agent's main history, `{"support", nil}`.

## Agent storage

| Backend | Keeps agents | Needs |
| --- | --- | --- |
| `WardrikCore.Backends.MemoryStore` | In memory, until the node stops | Nothing |
| `EKVStore` | On disk, on each node | `{:ekv, "~> 0.4"}` |
| `ObjectStore` | In an S3-compatible bucket | Bucket and credentials |
| `MirrorStore` | In two backends, while you migrate | The two backends |

The last three are under `DurableServer.Backends`.

Alternative supervision-tree fragment for disk storage; add `{:ekv, "~> 0.4"}` to your dependencies:

```elixir
children = [
  {EKV, name: :agents, data_dir: "/var/lib/my_app/agents", cluster_size: 1},
  {WardrikCore, backend: {DurableServer.Backends.EKVStore, name: :agents}}
]
```

Alternative supervision-tree fragment for S3 storage; set the AWS credential environment variables before startup:

```elixir
children = [
  {WardrikCore,
   backend:
     {DurableServer.Backends.ObjectStore,
      bucket: "my-app-agents",
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      s3_endpoint: "https://s3.amazonaws.com",
      default_region: "us-east-1"}}
]
```

To keep agents in Postgres, use `WardrikStore.Durable` from
[wardrik_store](https://hexdocs.pm/wardrik_store).

## Crash recovery

- An agent that crashes restarts and picks its message back up.
- With a backend that keeps agents, so does one whose node died. A sweep finds it every
  `:discovery_interval_ms` (`60_000` by default).
- A turn resumes from its last checkpoint, without calling the model again.
- A lost tool call runs again if its tool is `read_only` or `idempotent`. Otherwise it parks as
  `:in_doubt`:

```elixir
{:tool_calls, [{call, {:park, :in_doubt}}]} = WardrikCore.parked(agent)

# Run it again
WardrikCore.resume(agent, %{call.id => :approve})

# Or tell the model it didn't run
WardrikCore.resume(agent, %{call.id => {:deny, "It may have run already."}})
```

## Options

See `WardrikCore.start_agent/2` for agent options and defaults.

`configure/2` changes them from the next turn:

```elixir
:ok =
  WardrikCore.configure(agent,
    instructions: "Answer in one sentence.",
    prices: %{"anthropic:claude-haiku-4-5" => [input: 1.0, output: 5.0]}
  )
```

## Control a running agent

| Function | Does |
| --- | --- |
| `ask/3` | Queues a message. A running turn ends at its next step |
| `interrupt/1` | Stops the running or parked turn |
| `kill/2` | Stops one running tool call. The model gets an error |
| `resume/3` | Resumes a parked turn |
| `status/1`, `history/1`, `parked/1` | What the agent is doing, has said, and waits on |
| `stop/1` | Stops the agent until it's started again |
| `delete/2` | Stops the agent and deletes it |
| `list/1`, `whereis/2` | Every saved agent, and the running process for one |
| `nodes/1`, `placements/1`, `move/3` | Cluster nodes, where each agent runs, and moving one |

```elixir
WardrikCore.status(agent)
#=> :idle

WardrikCore.list()
#=> [{"support", nil}, {"support", "C1"}]

:ok = WardrikCore.delete({"support", "C1"})
```
