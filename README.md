# WardrikACP

Gives [WardrikCore](https://hexdocs.pm/wardrik_core) agents coding agents, such as Claude Code, as
tools. Each coding agent runs over the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP).

## Install

```elixir
def deps do
  [
    {:wardrik_acp, "~> 0.1.0-rc.1"}
  ]
end
```

Follow [Get started](guides/getting-started.md) to run Claude Code end to end in IEx.

## Start it

```elixir
children = [
  {WardrikACP,
   name: MyApp.ACP,
   worktrees: "/var/lib/my_app/worktrees",
   checkouts: [billing: [path: "/srv/billing", base: "origin/main", fetch: true]],
   harnesses: [
     claude: [
       command: "claude-agent-acp",
       env: %{"ANTHROPIC_API_KEY" => System.fetch_env!("ANTHROPIC_API_KEY")},
       meta: %{"claudeCode" => %{"options" => %{"settingSources" => []}}},
       context: ["CLAUDE.md", "AGENTS.md"]
     ]
   ]}
]
```

- Each harness is a coding agent that speaks ACP over stdio. Every option is in
  `WardrikACP.Harness`.
- A checkout is a git repository with at least one commit. Its options are in
  `WardrikACP.Checkout`.
- A coding agent starts when a call first needs it. It stops after `idle` milliseconds with no
  call attached.
- `settingSources: []` stops Claude Code from loading `~/.claude` and the repository's
  `.claude/settings.json`, so neither one can allow a tool.

## Give an agent the tool

```elixir
WardrikCore.start_agent(
  agent_id: "builder",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikACP, name: MyApp.ACP, harnesses: [:claude]}],
  middleware: [
    {WardrikPolicy.Middleware,
     WardrikPolicy.new!(deny: ["claude/delete"], default: [read_only: :allow, else: :ask])}
  ]
)
```

The model calls `claude` with these arguments:

| Argument | Value |
|---|---|
| `task` | What to do. |
| `checkout` | The name of a checkout. |
| `work` | A name for the piece of work, such as `fix-login`. |

- Each `work` name has its own worktree, branch and session. A later call with the same name
  continues them.
- The branch is `wardrik/<agent>/<conversation>/<work>`, cut from the checkout's `base`.
- Pass `checkouts: [:billing]` to limit the checkouts an agent may use.

The call returns a map:

```elixir
%{
  "message" => "Fixed the login redirect and added a test.",
  "stop_reason" => "end_turn",
  "branch" => "wardrik/builder/_/fix-login",
  "worktree" => "/var/lib/my_app/worktrees/claude/billing/builder/_/fix-login",
  "head" => "9c1e2f0...",
  "commits" => [%{"sha" => "9c1e2f0...", "subject" => "Fix the login redirect"}],
  "refused" => []
}
```

- `message` is the text the coding agent sent after its last tool call.
- `refused` lists each request the middleware refused, with its reason.

## Permission requests

Each permission request from the coding agent runs through the agent's middleware as a tool call.

| ACP request | Tool call |
|---|---|
| tool kind | name, as `claude__execute` (`claude/execute` in a policy) |
| `rawInput` | arguments, such as `%{"command" => "mix test"}` |
| `locations` | resources, so `"claude/edit(lib/*)"` matches by path |

- Kinds `read`, `search`, `think` and `fetch` are `read_only`. `delete` is `destructive`. Every
  other kind is `gated`.
- An approval answers `allow_once`. A refusal answers `reject_once`. `allow_always` is never
  chosen.
- After a `fetch`, the call's later requests and its answer carry the `"outside"` label.
- Each request's ID is `<call ID>:<ACP toolCallId>`, so events show it as a call of its own.
- A parked request parks the call. Answer the call, and the answer goes to the request:

```elixir
WardrikCore.resume(agent, %{"call_123" => :approve}, %{by: "user:maria"})
```

## Parked, stopped and restarted

| Event | What the next call does |
|---|---|
| A request parked. The coding agent is still running. | Answers the request it holds. |
| A request parked. The coding agent stopped. | Loads or resumes the session, or starts one. Sends the person's decision, and allows that request once. |
| Wardrik restarted while the call ran. | The call parks as `:in_doubt`. On approval, the coding agent is told to check the worktree and finish. |
| The call was stopped or timed out. | The prompt was cancelled. The next call sends a new prompt. |

## Clean up worktrees

```elixir
WardrikACP.sweep(MyApp.ACP)
#=> ["/var/lib/my_app/worktrees/claude/billing/builder/_/fix-login"]
```

- A sweep removes each worktree whose work is in its checkout's `base`, with its branch. Merged,
  squashed and cherry-picked work all count.
- A worktree stays while a call uses its coding agent, while a request waits, and while it has
  changes or untracked files. An idle coding agent is stopped first.
- A sweep runs at start, then every `sweep` milliseconds: a day unless set. `sweep: :infinity`
  turns it off.

## Costs

A `usage_update` with a cost in `USD` adds what each call spent to the call's `usd` measurement.
Budgets count it.

## Telemetry

- `[:wardrik_acp, :update]` for each ACP session update. Metadata: `:agent_id`, `:span`,
  `:harness`, `:update`.
- `[:wardrik_acp, :sweep]` after each sweep. Measurements: `:removed`. Metadata: `:acp`,
  `:removed`.

## With Wardrik

```elixir
config :my_app, MyApp.AgentRuntime,
  capabilities: [coding: {WardrikACP, name: MyApp.ACP, harnesses: [:claude]}]
```

Start `WardrikACP` before `MyApp.AgentRuntime`. A definition names the tool:

```elixir
Wardrik.Agent.define(scope, "agt_builder",
  model: "anthropic:claude-haiku-4-5",
  tools: ["coding"],
  policy: [default: [read_only: :allow, else: :ask]]
)
```

## Related

- [WardrikCore](https://hexdocs.pm/wardrik_core): the agent runtime.
- [WardrikPolicy](https://hexdocs.pm/wardrik_policy): rules, judges and budgets.
- [WardrikMCP](https://hexdocs.pm/wardrik_mcp): the tools of MCP servers.
- [Wardrik](https://hexdocs.pm/wardrik): agents, governed.

## License

Apache-2.0
