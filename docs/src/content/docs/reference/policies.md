---
title: "Policies"
description: "A policy decides each tool call an agent makes before it runs: the call runs, waits on a person, or is refused, and the model is told why."
editUrl: "https://github.com/wardrik-dev/wardrik/edit/main/packages/wardrik_policy/guides/policies.md"
sidebar:
  order: 4
---

<!-- Written by mix wardrik.docs from packages/wardrik_policy/guides/policies.md. Edit it there, not here. -->

A policy decides each tool call an agent makes before it runs: the call runs, waits on a person, or
is refused, and the model is told why.

```yaml
# ~/.config/wardrik/policies/careful.yaml
allow: [web_search, linear/*]
ask:
  github/create_*: This opens an issue on GitHub.
deny: [run_lua]
default: allow
```

A policy is a file in `policies/` under the config directory, which an agent names, or rules an
agent file writes in place. See [Policy and approvals](/concepts/policy/)
for how to choose them.

## Keys

| Key | Takes | Means |
| --- | --- | --- |
| `allow` | patterns, or a map of pattern to message | calls that run |
| `ask` | patterns, or a map of pattern to message | calls that wait on a person |
| `deny` | patterns, or a map of pattern to message | calls that are refused |
| `default` | `allow`, `ask` or `deny` | what decides a call no rule names; `allow` unless set |
| `allow_after` | a map of label to patterns, or to a map of pattern to message | calls allowed by name even after the run has read what the label marks; see [After content from outside](#after-content-from-outside) |
| `budget` | a budget | what the agent may spend; see [Budgets](#budgets) |
| `judge` | a judge | questions a model answers about each call; see [Judges](#judges) |

A message is what the person is asked, or what the model is told it may not do. Without one, an ask
says "github/create_issue needs your approval." and a deny "run_lua is not allowed for this agent."

## Patterns

A pattern names tools. A tool of an MCP server is named as `server/tool`, so `github/*` is every
tool of the server `config.yaml` calls `github`, and `*` alone is every tool. `*` stands for any run
of characters, `/` included, and is the only wildcard.

| Pattern | Names |
| --- | --- |
| `web_search` | one tool |
| `github/create_*` | the tools of `github` whose names begin `create_` |
| `write_file(notes/*)` | calls to `write_file` that act on something under `notes/` |
| `books/create_bill(amount < 100)` | calls to `books/create_bill` whose `amount` is under 100 |

### What a call acts on

Parentheses after the tool name what a call acts on: a file tool's path, or the glob of
`list_files` and `search_files`. `*` matches across folders, so `notes/*` names `notes/2026/10.md`.

```yaml
allow: [write_file(notes/*)]
ask: [delete_file(*)]
```

### Conditions on arguments

Parentheses may hold conditions on the call's arguments instead, comma-separated, all of which must
hold:

```yaml
allow:
  - books/list_*
  - books/create_bill(amount < 100)
ask: [books/create_bill(amount >= 100)]
deny:
  books/*(account = Payroll): Payroll is not for this agent.
  bank/transfer(amount > 5000, currency = USD): Large transfers go through finance.
```

| Condition | Holds where the argument |
| --- | --- |
| `name = value` | is the value, ignoring case, with `*` for any run of characters |
| `name != value` | is not the value |
| `name > 5`, `>=`, `<`, `<=` | is a number that compares so |

An argument is named by its key, or by keys joined with dots, `vendor.name`. Through a list the path
names each item's: `lines.amount` is the amount of each line, and a condition on it holds where it
holds for every line. A value in double quotes may hold commas, and an unquoted number compares as a
number. Text that reads whole as a number, such as `"600"`, counts as one.

A call that leaves an argument out is one no condition on it holds for. A call that gives it in a
form the condition can't check, such as text where a number is compared, is one an `ask` or `deny`
speaks for and an `allow` does not.

Write `name = value`, never `name: value`: YAML reads `: ` as the end of a key.

## How a call is decided

Every rule naming a call speaks for it, and the strictest decides: `deny` over `ask` over `allow`. A
call no rule names is decided by `default`.

A rule naming what a call acts on decides it when it is a `deny` or an `ask`. An `allow` lets the
call run only where allow rules name everything it acts on; otherwise `default` decides.

The rules decide tool calls only. Every model call passes them, and a [budget](#budgets) is what
limits model calls.

### Allowed by name

A call an `allow` rule names is allowed by name. A gated tool, one that may change something, such
as opening an issue, waits on a person unless its call is allowed by name, so `default: allow` alone
never lets it run. An MCP server's or a tool worker's tools are gated unless they are marked
read-only, and a server's `gated` in `config.yaml` decides instead; see
[Gated tools](/concepts/rules/#gated-tools).

## After content from outside

Once a run has read content from outside, such as a web page, a search result or an issue anyone
can file, it carries the label `outside` until its conversation is cleared. From then on a gated
tool's call waits on a person however the rules allowed it, since what the run read may be what
asked for it.

`allow_after` allows by name as `allow` does, and holds after its label too. It is for tools whose
calls may follow what a stranger wrote, because they reach nothing a stranger could take, or can do
little harm:

```yaml
allow: [linear/*]
allow_after:
  outside: [github/add_labels]
```

## Budgets

```yaml
budget:
  usd: 5.00
  tokens: 200000
  per: day
  on_exhausted: ask
```

| Key | Means |
| --- | --- |
| `usd` | a limit in US dollars, for model calls and for tool calls that have a price |
| `tokens` | a limit in tokens, input and output together |
| `per` | `turn`, `day`, `week`, `month`, or `total` for the agent's whole life; `day` unless set |
| `timezone` | the time zone a day, week or month begins in, by its IANA name, as `Europe/Berlin`; `Etc/UTC` unless set |
| `grant` | how much more a person's approval allows, as `usd` and `tokens`; another of each limit unless set |
| `on_exhausted` | `ask` parks the agent until a person approves more; `deny` ends the turn; `ask` unless set |

A budget sets `usd`, `tokens`, or both, and is spent when either is. Days, weeks and months are
calendar periods in `timezone`, and a week starts on Monday. Where the zone's clocks change, a day
is 23 or 25 hours long, and a changed `timezone` can start the current period over. A turn's budget covers every delegation under it.

The limits are checked before each model call against what the calls before it spent, so the call
that crosses one runs and the next stops. Tool calls are counted and never refused. A budget in
dollars refuses a model whose price isn't known; a token limit governs one, or one a subscription
pays for.

## Judges

A judge asks a model yes-or-no questions about each call, and decides by the probability of yes.

```yaml
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
```

| Key | Means |
| --- | --- |
| `model` | an evaluation model, `typesafe:jev-latest` unless set |
| `questions` | the questions; each takes the keys below |
| `question` | what the model is asked about the call |
| `tools` | the patterns of the calls it is asked about; every call unless set |
| `deny` | refuse the call at or above this probability |
| `ask` | ask a person first at or above this probability |
| `allow` | allow the call by name below this probability, where the run has read nothing from outside |
| `message` | what the person is asked, or the model told, in place of the question |

Across questions and rules, deny is over ask over allow: a judge's allow never lifts a call a rule
asks about or denies. A judge that can't answer asks a person where one of its questions could ask
or deny, and otherwise says nothing.

A call's arguments may be written by what the run read, and so written to fool the judge. A judge is
a second opinion beside the rules, not a replacement for them; try its thresholds on calls like the
agent's before trusting them. See [Judged
calls](/concepts/judges/).
