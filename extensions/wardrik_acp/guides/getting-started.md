# Get started

Run Claude Code as a tool of a WardrikCore agent, from a fresh IEx session. The agent sends
Claude Code a task. Claude Code asks before each change. You approve, see the commit, then sweep
the worktree once the work is merged.

Requires Node.js, git, an Anthropic API key, and Claude Code signed in or the same key.

## 1. Install the ACP adapter

```sh
npm install -g @agentclientprotocol/claude-agent-acp
claude-agent-acp --version
```

`claude-agent-acp` runs Claude Code over ACP. It uses Claude Code's sign-in from `~/.claude`, or
`ANTHROPIC_API_KEY` from the harness's `env`.

## 2. Make a repository

```sh
mkdir -p ~/acp-demo && cd ~/acp-demo
git init -b main
printf 'defmodule Demo do\n  def hello, do: "Hello"\nend\n' > demo.ex
printf '# Demo\n\nOne module, demo.ex. Keep changes small.\n' > AGENTS.md
git add . && git commit -m "First"
```

## 3. Start WardrikACP

Start `iex`, then paste this with your key:

```elixir
Mix.install([
  {:wardrik_acp, "~> 0.1.0-rc.2"},
  {:wardrik_policy, "~> 0.1.0-rc.3"}
])

System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")
demo = Path.expand("~/acp-demo")

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}},
  {WardrikACP,
   name: :acp,
   worktrees: Path.expand("~/acp-demo-worktrees"),
   checkouts: [demo: demo],
   harnesses: [
     claude: [
       command: "claude-agent-acp",
       env: %{"ANTHROPIC_API_KEY" => System.fetch_env!("ANTHROPIC_API_KEY")},
       meta: %{"claudeCode" => %{"options" => %{"settingSources" => []}}},
       options: %{"mode" => "default"},
       context: ["AGENTS.md"]
     ]
   ]}
]

{:ok, _} = Supervisor.start_link(children, strategy: :rest_for_one)
```

- `settingSources: []` stops Claude Code from loading `~/.claude/settings.json` and the
  repository's `.claude/`, so neither one can allow a tool.
- `mode: default` makes Claude Code ask before each change. Its own default, `auto`, may not ask.
- `AGENTS.md` is added to Claude Code's instructions.

## 4. Watch what Claude Code does

```elixir
:telemetry.attach("claude", [:wardrik_acp, :update], fn _name, _measured, %{update: update}, _config ->
  case update do
    %{"sessionUpdate" => "tool_call", "title" => title} -> IO.puts("claude: #{title}")
    _other -> :ok
  end
end, nil)
```

## 5. Start an agent

```elixir
policy = WardrikPolicy.new!(deny: ["claude/delete"], default: [read_only: :allow, else: :ask])

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "builder",
    model: "anthropic:claude-haiku-4-5",
    instructions: "You send coding work to the claude tool, then say what it did.",
    capabilities: [{WardrikACP, name: :acp, harnesses: [:claude]}],
    middleware: [{WardrikPolicy.Middleware, policy}]
  )
```

- Claude Code's reads and searches run. Its edits and commands ask a person.
- A delete is refused, and Claude Code is told so.

## 6. Ask for a change

```elixir
:ok =
  WardrikCore.ask(agent, """
  Use claude on the demo checkout, work add-greet: add greet/1 to demo.ex, returning
  "Hello, NAME!", then commit it.
  """)

defmodule Wait do
  def idle(agent) do
    Process.sleep(1_000)
    if WardrikCore.status(agent) == :running, do: idle(agent), else: WardrikCore.status(agent)
  end
end

Wait.idle(agent)
#=> :waiting
```

`:waiting` means a request needs your answer.

## 7. Answer each request

```elixir
{:tool_calls, [{call, {:park, ask}}]} = WardrikCore.parked(agent)
ask.message
#=> "claude/edit needs your approval."
ask.call.arguments
#=> %{"file_path" => ".../demo.ex", "old_string" => "...", "new_string" => "..."}

:ok = WardrikCore.resume(agent, %{call.id => :approve}, %{by: "you"})
Wait.idle(agent)
```

- `call` is the agent's `claude` call. `ask.call` is Claude Code's request, named by its ACP kind.
- Approve each request the same way until `Wait.idle(agent)` returns `:idle`.
- To refuse one: `WardrikCore.resume(agent, %{call.id => {:deny, "Not that file."}})`. Claude Code
  receives the refusal and carries on without it.

## 8. See the result

```elixir
agent |> WardrikCore.history() |> List.last()
#=> #Message<:assistant "Claude added greet/1 to demo.ex and committed it on wardrik/builder/_/add-greet.">
```

```sh
cd ~/acp-demo
git log --oneline main..wardrik/builder/_/add-greet
git diff main wardrik/builder/_/add-greet
```

The worktree is in `~/acp-demo-worktrees/claude/demo/builder/_/add-greet`. `main` is unchanged.

## 9. Continue the same work

```elixir
:ok = WardrikCore.ask(agent, "Use claude on the same work, add-greet: add a doc to greet/1, then commit.")
Wait.idle(agent)
```

The same `work` name resumes the session and branch. Answer each request as in step 7.

## 10. Merge, then sweep

```sh
cd ~/acp-demo
git merge --squash wardrik/builder/_/add-greet && git commit -m "Add greet/1"
```

```elixir
WardrikACP.sweep(:acp)
#=> [".../acp-demo-worktrees/claude/demo/builder/_/add-greet"]
```

The sweep removes the worktree and its branch, since `main` has the work. A sweep also runs every
day.

## Next

- `WardrikACP.Harness` for every harness option, and `WardrikACP.Checkout` for `base` and `fetch`.
- [WardrikPolicy](https://hexdocs.pm/wardrik_policy) for rules that match a request's arguments,
  such as `"claude/execute(command = mix test)"`.
