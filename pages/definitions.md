# Define agents

A definition says what an agent is and what it may do: its model, its instructions, its tools and
its policy. Define an agent, and Wardrik starts it, keeps the definition, and starts it again from
the definition whenever it wakes. It's the same definition an agent file's frontmatter writes, over
HTTP, from a CLI, or from your code.

## Offer what agents may use

Give Wardrik the tools and policies a definition may name:

```elixir
Wardrik.new(
  name: MyApp.Wardrik,
  data_dir: "/var/lib/my_app",
  capabilities: [files: {MyApp.Files, []}, run_lua: MyApp.Lua],
  policies: [careful: [ask: ["github/*"], deny: ["shell/*"]]],
  mcp: [github: [transport: {:stdio, command: "github-mcp-server", args: ["stdio"]}]]
)
```

| Option | Takes | Unless set |
| --- | --- | --- |
| `capabilities` | the tools a definition names, each a `WardrikCore.Capability` | none |
| `policies` | the policies a definition names, each as its rules | none |
| `mcp` | the MCP servers a definition names as `github/*` | none |
| `middleware` | what wraps every agent's calls | none |
| `idle_timeout` | the seconds a defined agent may have nothing to do before it sleeps, or `:infinity` | 900 |

## Define one

```elixir
definition =
  Wardrik.Definition.new!(
    model: "anthropic:claude-haiku-4-5",
    instructions: "You write the daily update on what landed on main.",
    tools: ["github/*", "files"],
    policy: [ask: ["github/create_*"], budget: [tokens: 400_000, per: :day]],
    timeout: 600
  )

{:ok, %{"status" => "idle"}} = Wardrik.Agent.define(scope, "acme/digest", definition)
```

Notice a definition is a map with string keys, as the protocol writes it, so a YAML file's
frontmatter, JSON over HTTP, and `Wardrik.Definition.new!/1` all give the same one.

| Key | Means |
| --- | --- |
| `model` | the model, as `provider:model`; required |
| `instructions` | the system prompt, sent with every model call |
| `tools` | what it may call: a capability by name, `server/*` for every tool of an MCP server, or `*` for all of them |
| `policy` | a policy by name, or its rules written in place, a budget and judge included |
| `timeout` | the seconds a turn may take |
| `max_iterations` | the rounds of tool calls a turn may make; 25 unless set |
| `idle_timeout` | the seconds it may have nothing to do before it sleeps, or `infinity` |
| `display_name`, `description` | what a person calls it, and what it's for |

A name it gives that Wardrik doesn't offer answers `invalid_request`. `workspace`, `context`,
`retries`, `compaction`, `triggers`, `notify` and `channels` are part of the definition, and answer
`not_supported` until the packages behind them land. Nothing in a definition is ignored.

Define it again to change it. A running agent takes the new definition from its next turn.

An agent of a user, as `acme/@maria/notes`, acts as `acme/@maria`, with her credentials. One of an
org, as `acme/digest`, acts as the org.

## Read it back

```elixir
{:ok, %{"definition" => definition, "missing" => missing}} =
  Wardrik.Agent.definition(scope, "acme/digest")
```

`missing` lists the tools it names that offer nothing yet, like an MCP server that's down.

## Sleep and wake

A defined agent sleeps once it has had nothing to do for its `idle_timeout`, and wakes when
something asks it, keeping its conversation. Asking, deciding and signing in wake it. Reading it
doesn't: it answers `asleep`.

| Function | Does |
| --- | --- |
| `Wardrik.Agent.stop/3` | puts it to sleep now |
| `Wardrik.Agent.spawn/3` | wakes it without asking it anything |
| `Wardrik.Agent.clear/3` | empties its conversation; `conflict` while it runs or waits on a person |
| `Wardrik.Agent.forget/3` | stops it and deletes its conversation and definition |
| `Wardrik.Agent.calls/3` | the tool calls it's running, each with how long it has run |
| `Wardrik.Agent.kill/4` | stops one call; the model gets an error for it, and the turn goes on |
| `Wardrik.Agents.cancel/2` | stops what every agent the patterns cover is doing |
| `Wardrik.Agents.forget/2` | forgets every agent the patterns cover |

Each change is recorded in the audit, with who made it.
