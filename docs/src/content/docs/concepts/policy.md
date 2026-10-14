---
title: Policy and approvals
description: Every tool call is decided before it runs; a policy says which calls run, which wait for a person, and which are refused.
sidebar:
  order: 2
---

Every tool call an agent makes is decided before it runs: it runs, it waits for a person, or it is
refused, and the model is told why. A policy is the file that says which.

```yaml title="~/.config/wardrik/policies/careful.yaml"
allow: [web_search, linear/*]
ask:
  github/create_*: This opens an issue on GitHub.
deny: [run_lua]
```

An agent names the file, or writes its rules in place:

```yaml
policy: careful
```

```yaml
policy:
  ask: [github/*]
  deny: [run_lua]
```

`wardrik reload` reads policy files again, with the agent files. Every key a policy takes is in
[Policies](/reference/policies/).

## How a call is decided

Each rule is a pattern naming tools. An MCP server's tool is `server/tool`, so `github/*` is every
tool of the server `config.yaml` calls `github`. `*` matches any run of characters, `/` included.

| Rules that name the call | The call |
| --- | --- |
| any `deny` | is refused |
| any `ask`, no `deny` | waits for a person |
| only `allow` | runs |
| none | follows `default`, which is `allow` unless set |

A rule's message is what the person is asked, or what the model is told. Rules decide tool calls
only; a [budget](#budgets) limits model calls.

### What a call acts on

A rule can name what a call acts on, in parentheses:

```yaml
allow: [write_file(notes/*)]
ask: [delete_file(*)]
```

File tools act on their path, or the glob for `list_files` and `search_files`. An allow covers a
call only if it names everything the call acts on; otherwise `default` decides.

### What a call's arguments are

The parentheses can hold conditions on the call's arguments instead:

```yaml
allow:
  - books/list_*
  - books/create_bill(amount < 100)
ask: [books/create_bill(amount >= 100)]
deny:
  books/*(account = Payroll): Payroll is not for this agent.
  email/send(to != *@example.com): Mail leaves the company only with a person's say-so.
```

Conditions use `=`, `!=`, `>`, `>=`, `<` and `<=`, and a comma means all must hold. See
[conditions on arguments](/reference/policies/#conditions-on-arguments) for every form, and
[Details](#arguments-the-model-writes) for how odd arguments are decided.

## Gated tools

A gated tool can change something, such as opening an issue or refunding an order. Its calls wait
for a person unless an `allow` rule names them. `default: allow` doesn't cover them, so an agent with
no policy still asks before a gated call.

An MCP server's tools are gated unless the server marks them read-only, with MCP's `readOnlyHint`.
`gated` in `config.yaml` overrides that:

```yaml
mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    gated: [create_*, issue_write]   # or true for every tool, false for none
```

A [tool worker](/build/tool-workers/)'s tools are gated unless marked read-only. The tools the daemon
ships are not gated.

## Content from outside

A turn carries a label for what it has read. Content from outside the deployment is labelled
`outside`. It comes from:

- `web_search` and `deep_research`;
- MCP servers not marked `trusted: true`;
- tool workers, unless `http.trusted_workers: true`;
- a file written by a turn that had read outside content.

Once a turn carries `outside`, every gated call waits for a person, whatever `allow` says. What it
read may be what asked for the call. The person is told so:

> github__create_issue is allowed, but this run has read content from outside, which may be what
> asked for it.

The label stays with the conversation until `wardrik clear AGENT` empties it.

### Allowing after content from outside

An agent that reads outside content, reaches private data and changes things needs a person; any
two of those are safe. `allow_after` allows a gated tool even after a label, for tools a stranger
can't misuse:

```yaml
allow: [linear/*]
allow_after:
  outside: [github/add_labels]
```

An `ask` or `deny` still wins over it.

## Waiting on a person

A call that waits parks the turn. Nothing more runs until each waiting call is decided. A parked
turn is stored, so it survives its node, and it never times out.

```sh
wardrik parked
wardrik approve acme/triage call_1 Label it for the next sprint.
wardrik deny acme/triage call_1 Not on a Friday.
```

```text
1 waiting:
  acme/triage  call_1  github/create_issue  This opens an issue on GitHub.
```

You can also decide in [Slack](/channels/slack/), where the call's arguments show with Approve and
Deny, in the [terminal client](/build/tui/), or with `POST /v1/agents/{key}/decisions`.

- **A denial** reaches the model as an error with your reason, and the turn carries on.
- **An approval** runs the call exactly as the model wrote it. A note is passed to the model beside
  the result; it steers what comes next but never changes the call. To change the call, deny it and
  say what to do.

### Changing the policy while it waits

`wardrik reload` re-decides calls a rule asked about, under the policy as it is now. Gated calls,
and calls waiting for an account, keep waiting.

## Judged calls

Some decisions turn on what a call means, not its name: does it change the books, does it send
money out? A `judge` asks a model yes-or-no questions about each call and acts on the probability.

```yaml title="~/.config/wardrik/policies/books.yaml"
ask: [books/delete_*]
judge:
  model: typesafe:jev-latest
  questions:
    - question: Does this call record, change or delete anything in the company's books?
      tools: [books/*]
      ask: 0.5
      allow: 0.05
    - question: Does this call send money to a person or an account outside the company?
      ask: 0.5
      deny: 0.9
      message: Money leaves the company only with a person's say-so.
```

| Key | When the probability is | The call |
| --- | --- | --- |
| `deny` | at or above it | is refused |
| `ask` | at or above it | waits for a person, who sees the question and the probability |
| `allow` | below it | is allowed by name |

Between the thresholds, the rules decide alone. The judge runs after the rules, so its allow never
lifts a rule's ask or deny.

:::caution
A judge is a second opinion beside the rules, not a replacement.

- **Its allow only holds before the run reads outside content.** Arguments can be written to fool it.
- **Calibrate it first.** Start with `ask` and `deny`, watch it on real calls, then add a low
  `allow`.
- **One thing per question.** Write two questions, not one with "and".
- **Exact matters go in rules.** A tool's name or a file's path is a rule's job.
:::

Try a judge on calls agents already made with `wardrik policy judge`; see
[Tuning a judge](#tuning-a-judge).

## Budgets

A budget caps what an agent spends on model calls and paid tools, in dollars, tokens or both:

```yaml
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  grant: {usd: 2.00}
  on_exhausted: ask   # or deny
```

Each model call is checked against what was already spent. The call that crosses the limit runs;
the next one parks:

> This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more.

Approving grants another limit's worth, or `grant`. `on_exhausted: deny` ends the turn instead.
`wardrik status`, `wardrik ls` and `wardrik show` show what each agent has spent. Every key is in
[Budgets](/reference/policies/#budgets).

## Details

### Arguments the model writes

Arguments come from the model, so rules meet forms they didn't expect:

- **A number written as text** counts as the number: `"600"` is more than 500.
- **A missing argument**, or null, or an empty list, matches no condition on it, `!=` included. A
  deny on `amount > 1000` doesn't stop a call with no amount; name the tool in a broader rule if
  that matters.
- **An argument that can't be compared**, such as `"$600"` against a number, could be anything. An
  ask or deny applies; an allow doesn't.
- **A list** matches an allow only if every item does, and an ask or deny if any item does.

A part in parentheses is a condition if it starts with an argument name and an operator; otherwise
it names what the call acts on, so `write_file(notes/*)` and paths with colons keep their meaning.
`name: value` is refused, with the `=` form to use instead.

### Writing rules in YAML

YAML reads a rule before the policy does:

- **`[ ]` splits at commas**, even quoted ones. Put a rule with several conditions on its own line
  after `-`, as a key, or in quotes: `deny: ["bank/transfer(amount > 5000, currency = USD)"]`.
- **` #` starts a comment.** Quote a value that starts with `#`: `books/*(memo = "#123")`.
- **`: ` ends a key**, even inside double quotes. Single-quote the whole rule:
  `- 'books/*(memo = "re: invoice")'`.

### When a turn is held

The `outside` label counts from the model's next round of calls. `DELETE
/v1/agents/{key}/conversation` clears it too. A label that `allow_after` names holds gated calls the
way `outside` does; a label no rule names is carried and shown, but holds nothing. A definition sent
over the HTTP API can name a policy that uses `allow_after`, but can't write the rule itself.

### While a call waits

- An agent's `timeout` starts again when the turn carries on.
- Messages that arrive wait behind the parked turn. `POST /v1/agents/{key}/cancel` abandons it.
- In a round of several calls, the allowed ones have already run. Each waiting call is decided on
  its own, in any order; the model gets the round's answers once all are decided.
- `wardrik approve` and `deny` without a call list what's waiting and ask which, if someone is at the
  terminal.
- Over HTTP, decide with `{"decisions": [{"id": "...", "decision": "approve"}]}`, adding a `"note"`,
  or `"decision": "reject"` with a `"reason"`. The token needs `decide`. The terminal client uses
  Ctrl-Y and Ctrl-N.
- `wardrik parked` and the HTTP API don't show a call's arguments; the Slack notice and the
  [webhook](/build/notices/#webhooks) do. Each shows what the turn had read: `wardrik parked` and
  Slack say so under the question, and the API and webhook carry `labels: ["outside"]`.
- An approval's note reaches the model as `"note"` beside the result:
  `{"ok": true, "result": {"number": 412}, "note": "Label it for the next sprint."}`. A note on a
  budget's question is recorded but not read by the model.
- A model call refused by a budget ends the turn.

### How a judge decides

The questions whose `tools` name a call, or all questions without `tools`, are asked together in one
request, with the tool's name and arguments. The call is allowed only if every question with an
`allow` is below its own. A refusal gives `message`, or the question, as the reason. A judge that
can't answer, because its model is unreachable or replies with nothing usable, asks a person if any
of its questions could ask or deny; otherwise it stays silent. `model` defaults to
`typesafe:jev-latest`; seal its key as any model key: `wardrik vault put TYPESAFE_API_KEY`.

### Tuning a judge

Uncertain calls land mid-range. Asked "Does this call send money outside the company?", one model
scored listing unpaid invoices 0.04, creating a $1,200 bill 0.52, and paying that bill 0.72, short of
a `deny` at 0.8.

- **For critical tools, widen the band a person sees.** Set `ask` at 0.3 or below and `deny` high.
  Better, name the tool in a rule, `ask: [bank/send_*]`, and let the judge catch what names miss.
- **Leave a margin under `allow`.** If harmless calls score 0.04 and risky ones 0.3, an `allow` of
  0.01–0.02 is safer than 0.05.
- **Say what counts.** The judge sees the question, the tool's name and its arguments, nothing else.
  "Does this call pay money out of the company's accounts now? Recording a bill does not count." took
  the bill from 0.52 to 0.05 and the payment to 0.77.
- **Name the tools.** A question without `tools` is asked of every call, adding a request to each.
- **Watch for a judge that can't answer:** a run of asks saying so.
- **Retest when the model changes.** A `latest` model can move.

`wardrik policy judge NAME` asks the judge again about calls agents made, without changing anything.
It reads the policy file as it is now, so you can adjust before `wardrik reload`, and marks with `!`
each call it would decide differently:

```text
$ wardrik policy judge books
books's judge on 2 calls of the agents under books, newest first; 1 decided otherwise than it would.

! books/send_payment  acme/books  2026-10-09 14:02:11Z
    arguments  {"amount":1200,"to":"Northwind"}
    0.72       Does this call send money to a person or an account outside the company?
    judge      asks a person
    decided    allowed by books
```

It tries the agents whose definitions name the policy, or those under `--agent` (an agent, or an
org as `acme/`), so you can test a judge before any agent uses it. `--last N` sets how many calls,
20 by default; `--json` gives the full answers. Only calls that ran are tried, and the log doesn't
record whether a run had read outside content, so an allow is shown as for a run that hadn't.

### How budgets count

- A budget covers the agent and every conversation it answers for, Slack threads and SDK sessions
  included. They share one meter, and a grant frees them all.
- Days, weeks and months are UTC; weeks start on Monday. A `turn` budget covers one turn and what
  it delegates. Tokens count input and output together.
- Prices come from the provider when it reports a cost, otherwise from the model catalog. A dollar
  budget refuses a model the catalog can't price; a token budget governs it, or a model a
  subscription pays for.
- A tool call counts its cost, failed or not: what the tool reports, as a
  [tool worker](/build/tool-workers/) can, or the price `config.yaml` lists under
  [`tools`](/reference/config/#tools). Tool calls are counted, never refused.
- Each call's event carries what was counted, as `cost` on
  [`message.completed`](/reference/events/#wardrikmessagecompleted) and
  [`tool_call.completed`](/reference/events/#wardriktool_callcompleted): whole micro-dollars, and who
  priced it. An unpriced model shows `null`, not zero. What an agent cost over any period is a read
  of its log.

### Policy files and reload

An agent whose policy doesn't read doesn't read either; one already running keeps the policy it
had.

### Connecting an account

A call that needs an account the user hasn't connected parks the same way, with a link to authorize
instead of a question; `wardrik parked` shows it. The call carries on once the account is connected.
See [Connect accounts](/build/accounts/).

### In Elixir

A policy is a `Wardrik.Hook`. An application using Wardrik as a library can give an agent its own
hooks: each sees every tool call and model call first, and can deny it, ask a person, or let it
run. `WardrikPolicy.hooks/1` turns a policy written as data into hooks, and an agent file can name a
hook module as its `policy`. A tool written in Elixir can declare itself gated.
