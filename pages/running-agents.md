# Run agents

## Setup

Paste this into a fresh IEx session. It keeps agents in memory, and needs an Anthropic key for the
model calls:

```elixir
Mix.install([{:wardrik_core, "~> 0.1.0-rc.1"}])
System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _} = Supervisor.start_link(children, strategy: :rest_for_one)
```

Replace `"sk-ant-..."` with your key. In an app, put the two children in your supervision tree
instead.

## Start an agent

```elixir
{:ok, agent} = WardrikCore.start_agent(agent_id: "support", model: "anthropic:claude-haiku-4-5")
:ok = WardrikCore.ask(agent, "What's on fire?")

WardrikCore.history(agent)
#=> [#Message<:user text>, #Message<:assistant text>]
```

`ask/3` returns once the message is stored. The agent answers in its own process.

A conversation runs on the same options, with a history of its own. Name it with `:conversation`:

```elixir
{:ok, thread} =
  WardrikCore.start_agent(
    agent_id: "support",
    conversation: "C1",
    model: "anthropic:claude-haiku-4-5"
  )
```

The agent ID and the conversation ID are your app's. Each `{agent_id, conversation}` is one agent.
The agent's own history is `{agent_id, nil}`. Functions that find an agent take its ID alone for
its own history:

```elixir
WardrikCore.whereis("support")
WardrikCore.whereis({"support", "C1"})
```

## Where agents are kept

`WardrikCore` saves agents through a [durable_server](https://hexdocs.pm/durable_server) backend:

| Backend | Keeps agents | Needs |
| --- | --- | --- |
| `MemoryStore` | In memory. Gone when the node stops. | Nothing. For tests and trying things out. |
| `EKVStore` | On disk, and on each node when clustered. | The `ekv` dependency, and `EKV` started before `WardrikCore`. |
| `ObjectStore` | In an S3-compatible bucket. | `bucket`, `access_key_id`, `secret_access_key`, `s3_endpoint` and `default_region`. |
| `MirrorStore` | In two backends at once, while you migrate between them. | The two backends. |

`MemoryStore` is `WardrikCore.Backends.MemoryStore`. The rest are under `DurableServer.Backends`.

To keep agents on disk, add `{:ekv, "~> 0.4"}` to your deps. Then start `EKV` first in your
supervision tree:

```elixir
children = [
  {EKV, name: :agents, data_dir: "/var/lib/my_app/agents", cluster_size: 1},
  {WardrikCore, backend: {DurableServer.Backends.EKVStore, name: :agents}}
]
```

An S3-compatible bucket needs no extra dependency:

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

To write your own backend, such as one for Postgres, implement durable_server's storage behaviour.
That behaviour isn't a stable contract yet, so expect changes between durable_server releases.

## When a node dies

An agent that crashes comes back by itself, as does one whose node dies, with a backend that keeps
agents. A sweep for lost agents restarts it, every `:discovery_interval_ms` (`60_000` unless set),
and it picks its message back up. A turn lost while its tools ran resumes from its last checkpoint,
without calling the model again. An agent stopped with `stop/1` stays stopped.

A tool call lost that way may already have run:

* If its tool is annotated `read_only: true` or `idempotent: true`, the call is repeated.
* Otherwise it parks as `:in_doubt`. Answer it with `resume/3`:

```elixir
{:tool_calls, [{call, {:park, :in_doubt}}]} = WardrikCore.parked(agent)

# Run it again
WardrikCore.resume(agent, %{call.id => :approve})

# Or tell the model it didn't run
WardrikCore.resume(agent, %{call.id => {:deny, "It may have run already."}})
```

## Options

`start_agent/2` also takes:

| Option | Takes | Default |
| --- | --- | --- |
| `instructions` | the system prompt, sent with every model call and never kept in the history | none |
| `capabilities` | modules that give the agent its tools. See [Tools](tools.md) | `[]` |
| `middleware` | what wraps every call. See [Middleware](middleware.md) | `[]` |
| `principal` | who the agent acts as. See [Principals](principals.md) | none |
| `credentials` | where tools find a person's credentials. See [Credentials](credentials.md) | none |
| `keys` | where code finds API keys. See [Keys](credentials.md#keys) | none |
| `events` | where its events go. See [Events](events.md) | none |
| `metadata` | anything of yours, passed to middleware | `%{}` |
| `timeout` | how long a turn may take, in milliseconds | `:infinity` |
| `max_rounds` | model calls a turn may make | `25` |
| `retries` | how failed calls are retried. See `WardrikCore.Retry` | `[]` |
| `prices` | model prices in US dollars per million tokens, by spec. Takes precedence over the model catalog | `%{}` |

`configure/2` changes them on a running agent, from its next turn:

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
| `ask/3` | Queues a message. A running turn ends at its next step, and the next turn answers it |
| `interrupt/1` | Stops the running or parked turn |
| `kill/2` | Stops one running tool call. The model gets an error, and the turn goes on |
| `resume/3` | Resumes a parked turn, with who answered as metadata |
| `status/1`, `history/1`, `parked/1` | What the agent is doing, what it has said, and what it's waiting on |
| `configure/2` | Changes the model or settings, from the next turn |
| `stop/1` | Stops the agent until it's started again |
| `delete/2` | Stops the agent and deletes its saved state |
| `list/1`, `whereis/2` | Every saved agent's `{agent_id, conversation}`, and the running agent for one |
| `nodes/1`, `placements/1` | The cluster's nodes, and the node each saved agent runs on |
| `move/3` | Restarts an agent on another node, with its saved state |

```elixir
WardrikCore.status(agent)
#=> :idle

WardrikCore.list()
#=> [{"support", nil}, {"support", "C1"}]

:ok = WardrikCore.delete({"support", "C1"})
```
