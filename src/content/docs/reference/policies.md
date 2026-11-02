---
title: "Policies"
description: "The keys of a policy file: which tool calls run, wait on a person, or are refused."
sidebar:
  order: 4
---

```yaml
# ~/.config/wardrik/policies/careful.yaml
allow: [web_search, linear/*, write_file(notes/*)]
ask:
  github/create_*: This opens an issue on GitHub.
  books/create_bill(amount >= 1000): A bill this size needs a person.
deny: [shell/*]
default: allow
budget: {usd: 5.00, per: day}
```

- A policy is `policies/NAME.yaml` in the [config directory](/reference/config/#directories). An agent names it as `policy: NAME`, or writes rules in place.
- The daemon reads `policies/` as it starts. Restart it after a change.
- The strictest rule wins: `deny`, then `ask`, then `allow`.
- See [Policy and approvals](/concepts/policy/) for how to choose rules.

## Keys

| Key | Takes | Description |
| --- | --- | --- |
| `allow` | patterns | calls that run |
| `ask` | patterns, or pattern to message | calls that wait on a person; the message is what they're asked |
| `deny` | patterns, or pattern to message | calls that are refused; the message is what the model is told |
| `default` | `allow`, `ask`, `deny`, or annotation to one | calls no rule names; `allow` unless set |
| `allow_after` | label to patterns | calls still allowed after the run reads content with that label |
| [`budget`](#budgets) | | what the agent may spend |
| [`judge`](#judges) | | yes-or-no questions a model answers about each call |

## Patterns

| Pattern | Matches |
| --- | --- |
| `web_search` | one tool |
| `github/*` | every tool of the MCP server `github` |
| `github/create_*` | its tools starting `create_` |
| `write_file(notes/*)` | calls that act on a path under `notes/` |
| `books/create_bill(amount >= 1000)` | calls whose `amount` is 1000 or more |
| `email/send(to != *@acme.com)` | calls whose `to` isn't at `acme.com` |
| `bank/transfer(amount > 5000, currency = USD)` | calls where every condition holds |

- `*` matches any run of characters, `/` included.
- The model sees `github/create_issue` as `github__create_issue`. A pattern matches either.
- Conditions: `=`, `!=`, `>`, `>=`, `<`, `<=`. `=` ignores case and takes `*`.
- `vendor.name` names a nested argument. `lines.amount` must hold for every line.
- A call missing the argument matches no condition on it.
- Write `name = value`, never `name: value`. YAML reads `: ` as a key.

## Defaults by annotation

```yaml
allow: [write_file(notes/*)]
default:
  read_only: allow
  else: ask
```

`else` covers tools with none of the annotations. The strictest of a tool's annotations wins.

## Gated tools and content from outside

- A gated tool may change something. It waits on a person unless a rule allows it by name; `default: allow` isn't enough.
- MCP and worker tools are gated unless marked read-only, or as `config.yaml`'s [`gated`](/reference/config/#mcp) says.
- Once a run reads content from outside (a web page, a search result, an issue), it's labelled `outside`.
  Then every gated call waits on a person, even if allowed.
- `allow_after` keeps named calls allowed after that:

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
  timezone: Europe/Berlin
  on_exhausted: ask
```

| Key | Default | Description |
| --- | --- | --- |
| `usd` | | limit in US dollars |
| `tokens` | | limit in tokens, input and output together |
| `per` | `day` | `turn`, `day`, `week`, `month` or `total` |
| `timezone` | `Etc/UTC` | where a day, week or month begins; weeks begin Monday |
| `grant` | one more limit | how much more an approval allows, as `{usd: 2.00}` |
| `price` | | `{input: 0.60, output: 2.20}` per million tokens, for a model with no known price |
| `on_exhausted` | `ask` | `ask` a person, or `deny` |

- It's checked before each model call. The call that crosses the limit still runs.
- Tool calls are counted, never refused.
- A dollar budget refuses a model with no price unless `price` is set. `config.yaml`'s [`models`](/reference/config/#models) adds prices.
- An org's policy, set in [`orgs`](/reference/config/#orgs), has one budget all its agents share.
  [`GET /v1/owners/{owner}/ceilings`](/reference/http-api/#list-ceilings) shows what they've spent.

## Judges

```yaml
judge:
  model: typesafe:jev-latest
  questions:
    - question: Does this call send money to an account outside the company?
      tools: [books/*]
      ask: 0.5
      deny: 0.9
```

| Key | Description |
| --- | --- |
| `model` | the model that answers; `typesafe:jev-latest` unless set |
| `questions[].question` | required; what the model is asked about the call |
| `questions[].tools` | patterns it applies to, without arguments; every tool unless set |
| `questions[].deny` | refuse at or above this probability (0 to 1) |
| `questions[].ask` | ask a person at or above this probability |
| `questions[].allow` | allow below this probability |
| `questions[].message` | the prompt or refusal, in place of the question |

- A question needs at least one of `deny`, `ask` and `allow`.
- A judge's `allow` only decides calls no rule names, and never after content from outside.
- If the model can't answer, the call asks a person when a question could ask or deny.
- Arguments can be written to fool a judge. Keep exact checks in rules.
