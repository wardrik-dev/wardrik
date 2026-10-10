---
title: Policy and approvals
description: How each tool call an agent makes is decided before it runs, how a call waits on a person, and how a budget limits what an agent spends.
sidebar:
  order: 3
---

Every tool call an agent makes is decided before it runs. It runs, it waits on a person, or it is
refused, and the model is told why. A policy is how you say which.

## Writing a policy

A policy is a file in `policies/` under the config directory:

```yaml title="~/.config/wardrik/policies/careful.yaml"
allow: [web_search, linear/*]
ask:
  github/create_*: This opens an issue on GitHub.
deny: [run_lua]
default: allow
```

An agent names it, or writes its rules in place:

```yaml
policy: careful
```

```yaml
policy:
  ask: [github/*]
  deny: [run_lua]
```

`wardrik reload` reads the policy files again, with the agent files. An agent whose policy does not
read does not read either, and one already running keeps the policy it had.

## How a call is decided

Each rule is a pattern naming tools. A tool of an MCP server is named as `server/tool`, so
`github/*` is every tool of the server `config.yaml` calls `github`. `*` stands for any run of
characters, `/` included, and is the only wildcard.

Every rule naming a call speaks for it, and the strictest decides: `deny` over `ask` over `allow`.
A call no rule names is decided by `default`, which is `allow` unless the policy says otherwise.

`allow`, `ask` and `deny` each take a list of patterns, or a map of pattern to message. A message is
what the person is asked, or what the model is told it may not do. Without one, an ask says
"github/create_issue needs your approval." and a deny "run_lua is not allowed for this agent."

The rules decide tool calls only. Every model call passes them, and a [budget](#budgets) is what
limits model calls.

### What a call acts on

A rule may name what a call acts on, in parentheses:

```yaml
allow: [write_file(notes/*)]
ask: [delete_file(*)]
```

The file tools say what their calls act on: the path, or the glob for `list_files` and
`search_files`. A deny or an ask naming what a call acts on decides it. An allow naming it lets the
call run only where the rule names everything the call acts on, and otherwise `default` decides.
Here, as in every rule, `*` matches across folders: `notes/*` names `notes/2026/10.md`.

### What a call's arguments are

A rule may say instead what a call's arguments must be, in the same parentheses, for any tool and an
MCP server's tools above all:

```yaml
allow:
  - books/list_*
  - books/create_bill(amount < 100)
ask: [books/create_bill(amount >= 100)]
deny:
  books/*(account = Payroll): Payroll is not for this agent.
  bank/transfer(amount > 5000, currency = USD): Large transfers go through finance.
  email/send(to != *@example.com): Mail leaves the company only with a person's say-so.
```

- `name = value` holds where the argument is the value, ignoring case, with `*` for any run of
  characters: `memo = refund*`. A value in double quotes may hold commas, and spaces at its ends.
- `name != value` holds where `name = value` does not: `to != *@example.com` for an address outside,
  `amount != 0`.
- `name > number`, `>=`, `<` and `<=` compare numbers: `amount > 500`.
- `vendor.name` names a key inside an object. Through a list it names each item's: `lines.amount`
  is the amount on every line.
- Several conditions, comma-separated, must all hold.

The parentheses hold conditions where each part begins with an argument's name and then `=`, `!=` or
a comparison, and what a call acts on otherwise, so `write_file(notes/*)` keeps its meaning, as does
a path or a URL with a colon in it. A part written `name: value` is refused, with the `=` to write
instead.

YAML reads a few things in a rule before the policy does:

- **A `[ ]` list splits a rule at its commas**, quoted values' too. Write a rule with several
  conditions on a line of its own after a `-`, as a key with its message, or in quotes:
  `deny: ["bank/transfer(amount > 5000, currency = USD)"]`.
- **A `#` after a space starts a comment**, so put a value that starts with `#` in double quotes:
  `books/*(memo = "#123")`.
- **`: ` ends a key, or makes a list item a key**, even in a value's double quotes. Put the whole
  rule in single quotes: `- 'books/*(memo = "re: invoice")'`.

A rule with conditions speaks for the whole of each call they hold for. Arguments are written by the
model, so they come in forms a rule did not foresee, and a rule decides those this way:

- **A number written as text** counts as the number: `"600"` is more than 500.
- **An argument a call leaves out**, or gives as null or as an empty list, is one no condition on it
  holds for, `!=` included. A deny on `cc != *@example.com` does not stop a message with no cc, which
  is what it is for; but a deny or an ask on `amount > 1000` does not stop a call with no amount
  either, so name the tool in a broader rule, or let `default` ask, where that matters.
- **An argument a rule cannot compare**, `"six hundred"` or `"$600"` against a number, or an object
  where it names a value, may be anything. A deny or an ask speaks for that call, and an allow does
  not.
- **A list** holds where every item does. A deny or an ask speaks where any item holds, so a deny on
  `to != *@example.com` stops a message with one outside address among many, and an allow speaks
  only where every item holds.

### Without a policy

An agent with no policy may make every call its tools allow, apart from a gated tool's.

## Gated tools

A gated tool is one that may change something, such as opening an issue or refunding an order. Its
calls ask a person by default: one runs without asking only where an `allow` rule names it.
`default: allow` covers the other tools, not gated ones, so a gated tool asks under a policy that
names nothing, as it does under none.

An MCP server's tools are gated unless the server marks them read-only, with MCP's `readOnlyHint`,
as an MCP client asks before a tool that may change something. `gated` in `config.yaml` decides
instead, by the names the server gives its tools:

```yaml
mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    gated: [create_*, issue_write]   # or true, for every tool, or false, for none
```

A [tool worker](/guides/tool-workers/)'s tool is gated unless the worker marks it read-only too. A
tool written in Elixir can say it is gated. The tools the daemon ships are not.

## Content from outside

A turn carries labels for what it has read. Content from outside the deployment is labelled
`outside`, and these tools bring it in:

- `web_search` and `deep_research`;
- every MCP server `config.yaml` does not mark `trusted: true`;
- tool workers, unless `http` in `config.yaml` says `trusted_workers: true`;
- a file a turn wrote after reading content from outside, when another turn reads it.

Once a turn carries `outside`, a gated tool's calls wait on a person however the `allow` rules
name them, since what the turn read may be what asked for the call. It counts from the next round
of calls the model makes. The person is told why:

> github__create_issue is allowed, but this run has read content from outside, which may be what
> asked for it.

What the turn read stays in the agent's conversation, so the turns after it carry the label and are
held the same way, until `wardrik clear AGENT`, or `DELETE /v1/agents/{key}/conversation`, empties
it.

### Allowing after content from outside

An agent may read content from outside, reach what is private, and change things: any two are
safe, and all three need a person. So `allow_after` allows a gated tool by name as `allow` does,
and holds after a label too. It is for a tool whose calls may follow what a stranger wrote, because
the agent reaches nothing they could take, or the tool can do little harm:

```yaml
allow: [linear/*]
allow_after:
  outside: [github/add_labels]
```

An ask or a deny still decides over it. A policy in `policies/` or an agent file may say it; a
definition sent to the HTTP API may name such a policy, but not write the rule itself.

A label `allow_after` names holds a gated tool's calls the way `outside` does. A label no rule names
is carried and shown, and holds nothing.

## Waiting on a person

A call that waits on a person parks the turn. Nothing more runs, nothing is added to the
conversation, and the agent holds what it was doing until each call it waits on is decided. A
parked turn is kept in the store, so it outlives the node it parked on, and it does not time out:
an agent's `timeout` starts again when the turn carries on.

Messages that arrive meanwhile wait behind it. `POST /v1/agents/{key}/cancel`
abandons it.

In a round of several calls, the ones the rules allowed have run already. Each call that waits is
decided on its own, in any order, and the model has the round's answers once every call is decided.

### Deciding

`wardrik parked` lists what is waiting:

```
1 waiting:
  acme/triage  call_1  github/create_issue  This opens an issue on GitHub.
```

`approve` and `deny` decide one call. `approve` takes a note for the model, and `deny` a reason:

```sh
wardrik approve acme/triage call_1
wardrik approve acme/triage call_1 Label it for the next sprint, not this one.
wardrik deny acme/triage call_1 Not on a Friday.
```

Without a call, they list the calls waiting and ask which, where there is someone at the terminal
to answer.

A call can also be decided:

- from Slack, where the notice shows the call's arguments, with Approve and Deny buttons. See
  [Slack](/channels/slack/);
- over the HTTP API, with a token that can `decide`:
  `POST /v1/agents/{key}/interrupts/{id}` with `{"decision": "approve"}`,
  `{"decision": "approve", "note": "..."}`, or `{"decision": "reject", "reason": "..."}`;
- in the [terminal client](/guides/tui/), with Ctrl-Y and Ctrl-N.

`wardrik parked` and the HTTP API do not show a call's arguments. The Slack notice and the
[webhook](/guides/notices/#webhooks) do.

Wherever a call is shown, it says what its turn had read first, which may be what asked for it:
`wardrik parked` and the Slack notice say so under the question, and the HTTP API and the webhook
carry the turn's labels, as `labels: ["outside"]`.

A denied tool call is answered with an error the model reads, carrying the reason, and the turn
carries on. A model call refused by a budget ends the turn.

An approved tool call runs, and where the person approving wrote a note, the model reads it beside
the call's answer, as `"note"`:

```json
{"ok": true, "result": {"number": 412}, "note": "Label it for the next sprint, not this one."}
```

A note cannot change the call: it runs with the arguments the model wrote, whatever the note says.
The note steers what the agent does next. To change the call itself, deny it and say what to do
instead, and the model can make the call again as asked. A note on a model call a budget asked
about is recorded, and not read by the model.

### Changing the policy while it waits

`wardrik reload` gives a waiting agent its policy as it is now, and the new rules decide the calls
a rule asked about: a call they allow runs without a person, one they deny is refused, and one they
ask about waits on what they ask now. A gated call, and one waiting on an account to be connected,
keeps waiting.

## Judged calls

Rules name tools, what file tools act on, and what a call's arguments are. Some decisions turn on
what a call means instead: whether it changes the books, whether it sends money out. A policy's
`judge` asks a model about each call, in words, and decides by how likely the answer is yes:

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

For each tool call, the questions whose `tools` name it, every tool's where they name none, are
asked together in one request, with the tool's name and its arguments. Each answer is the
probability of yes, and a question decides by it:

| | When the probability is | The call |
| --- | --- | --- |
| `deny` | at or above it | is refused, with `message` or the question as the reason |
| `ask` | at or above it | waits on a person, who is shown `message` or the question and how likely it was |
| `allow` | below it | is allowed by name, as an `allow` rule allows one, where every question with an `allow` is below its own |

Anything in between leaves the call to the rules, as if there were no judge: a gated tool's call
still waits on a person. The judge is a hook after the rules, so the strictest answer decides: its
allow never lifts a call a rule asks about or denies, and its ask or deny holds whatever the rules
allow. A judge that cannot answer, because the model is unreachable or answers nothing it can use,
asks a person where one of its questions could have asked or denied, and otherwise says nothing.

`model` is any evaluation model, `typesafe:jev-latest` by default. Its key is a model key, kept as
the others are: `wardrik vault put TYPESAFE_API_KEY`.

:::caution
A judge is a second opinion beside the rules, not a replacement for them.

- **Its allow holds only while the run has read nothing from outside.** A call's arguments may have
  been written by a web page or an email the agent read, to look harmless to the judge. Once the run
  carries the `outside` label, the judge can still ask and deny, but never allow.
- **Its probabilities are not yet yours.** The model is calibrated in general, not on your agents'
  calls. Start with `ask` and `deny`, watch what it decides on calls like the agent's, and add an
  `allow` only well below where it asked, for questions whose answer the call's arguments settle.
- **Ask one thing per question.** "Does it change the books and send money?" is two questions;
  write two, and let each decide.
- **Rules for exact matters.** A tool's name, or the file a call writes, is a rule's to decide: a
  judge is for what a call means.
:::

### Tuning a judge

A judge's answers are probabilities, and a call that could be read two ways lands in the middle. Asked
"Does this call send money to a person or an account outside the company?", one model gave a call
listing unpaid invoices 0.04, a call creating a $1,200 bill 0.52, and a call paying that bill 0.72.
The listing is clear, but the bill, which records money owed rather than paying it, is not, and the
payment fell short of a `deny` set at 0.8. Some gotchas, and what to do about each:

- **For critical things, widen the band a person sees.** Set `ask` low, 0.3 or below, and `deny`
  high, so everything uncertain waits on a person, and only what the judge is sure of is refused
  without one. Better still, name the tool in a rule: `ask: [bank/send_*]` holds whatever the judge
  thinks, and the judge is left to catch what the names miss.
- **Leave a margin under `allow`.** Allow only well below where calls you would want to see land:
  if harmless calls score 0.04 and risky ones 0.3 or more, an `allow` of 0.01 to 0.02 is safer than
  0.05. A probability just under the line is not much surer than one just over it.
- **Say what counts in the question.** The judge sees the question, the tool's name and its
  arguments, not the tool's description or the conversation. "Does this call pay money out of the
  company's accounts now? Recording a bill or an invoice does not count." took the bill from 0.52
  to 0.05, and the payment to 0.77: clearer, though still short of a `deny` at 0.8, which is why
  the band a person sees matters.
- **Ask one thing per question.** "Does it change the books and send money?" judges both at once;
  write two questions, and let each decide.
- **Name the tools a question is about.** A question without `tools` is asked of every call, which
  adds a request, and its wait, to each one. `tools: [books/*]` keeps it to the calls it is for.
- **Expect a judge that cannot answer.** When the model is unreachable, a judge with an `ask` or a
  `deny` asks a person, so the agent waits rather than acting; one with only `allow` falls back to the
  rules. Watch for a run of asks that say the judge could not answer.
- **Check again when the model changes.** A model named `latest` can move. Try the judge on calls
  like the agent's after an update, and before raising any threshold.

`wardrik policy judge NAME` tries a policy's judge on the calls agents have made, without deciding
or changing anything. It reads the policy from its file as it is now, so a threshold or a question
can be changed and tried again before `wardrik reload`. Its model answers each question again, and
what that decides is set beside how the call was decided when it was made, with `!` where they
differ:

```sh
$ wardrik policy judge books
books's judge on 2 calls of the agents under books, newest first; 1 decided otherwise than it would.

! books/send_payment  acme/books  2026-10-09 14:02:11Z
    arguments  {"amount":1200,"to":"Northwind"}
    0.81       Does this call record, change or delete anything in the company's books?
    0.72       Does this call send money to a person or an account outside the company?
    judge      asks a person: Judged 81% likely: Does this call record, change or delete anything in the company's books?
    decided    allowed by books

  books/list_invoices  acme/books  2026-10-09 13:58:40Z
    arguments  {"status":"unpaid"}
    0.03       Does this call record, change or delete anything in the company's books?
    0.04       Does this call send money to a person or an account outside the company?
    judge      allows it
    decided    allowed by books

Only calls that ran are tried. Its allow holds only where the run had read nothing from outside, which the log does not say.
```

The calls are those of the agents whose definitions name the policy, with their conversations, or
those under `--agent`: an agent, as `acme/books`, or every agent of an org, as `acme/`, whatever
policy they run under, so a judge can be tried before any agent is held to it. `--last N` is how
many, newest first, 20 by default, and `--json` answers with each call's answers, what they decide,
and how it was decided.

Only calls that ran are tried: a log keeps no arguments of a call that was refused, or that is still
waiting on a person. Nor does it say whether the run had read anything from outside by then, so a
judge's allow is shown as it would be for a run that had not.

## Budgets

A policy may hold a budget for what the agent spends on model calls, in dollars, in tokens, or
both:

```yaml
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  on_exhausted: ask   # or deny
```

- `per` is the period, `day` unless set. Days, weeks and months are UTC calendar ones, weeks from
  Monday. A `turn` budget covers one turn, with what it delegates.
- Tokens count input and output together.
- Each model call is checked against what was spent before it. The call that crosses a limit runs,
  and the next one parks, with "This agent has spent $5.02 of $5.00 today. Approve to allow $5.00
  more."
- Approving grants another limit's worth for the period, or the budget's `grant`, which takes
  `usd` and `tokens`.
- `on_exhausted: deny` ends the turn instead of asking.

Prices come from the provider where it reports what a call cost, and from the model catalog
otherwise. A dollar budget refuses every call to a model the catalog cannot price; a budget in
tokens alone governs such a model, or one a subscription pays for.

`wardrik status`, `wardrik ls` and `wardrik show` show what each agent has spent in its period.
Tool calls are not metered.

## Connecting an account

A tool that needs an account the user has not connected parks its call the same way, with a link
to authorize instead of a question, and `wardrik parked` shows the link. The call carries on by
itself once the account is connected. See [Connect accounts](/guides/accounts/).

## In Elixir

A policy is a `Wardrik.Hook`, and an application running Wardrik as a library gives an agent hooks
of its own: each is handed every tool call and model call before it happens, and may deny it, ask a
person about it, or leave it be. `WardrikPolicy.hooks/1` gives the hooks a policy written as data
is. An agent file names a hook module as its `policy`.
