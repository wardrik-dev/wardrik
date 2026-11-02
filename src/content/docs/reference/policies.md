---
title: "Policies"
description: "The keys of a policy file, which define whether each tool call runs, needs approval, or is denied."
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

- A policy is `policies/NAME.yaml` in the [config directory](/reference/config/#directories). Reference it with `policy: NAME`, or write rules inline.
- The daemon reads `policies/` at startup. Restart it after a change.
- The strictest rule wins: `deny`, then `ask`, then `allow`.
- See [Policy](/concepts/policy/) for examples.

## Keys

| Key | Takes | Description |
| --- | --- | --- |
| `allow` | patterns | calls that run |
| `ask` | patterns, or pattern to message | calls that need approval; the message is shown to the approver |
| `deny` | patterns, or pattern to message | calls that are denied; the message is returned to the model |
| `default` | `allow`, `ask`, `deny`, or annotation to one | calls no rule matches; default `allow` |
| `allow_after` | label to patterns | calls still allowed after the turn reads content with that label |
| [`budget`](#budgets) | | the agent's spend limit |
| [`judge`](#judges) | | yes-or-no questions a model answers about each call |

## Patterns

| Pattern | Matches |
| --- | --- |
| `web_search` | one tool |
| `github/*` | every tool of the MCP server `github` |
| `github/create_*` | its tools starting with `create_` |
| `write_file(notes/*)` | calls on a path under `notes/` |
| `books/create_bill(amount >= 1000)` | calls whose `amount` is 1000 or more |
| `email/send(to != *@acme.com)` | calls whose `to` isn't at `acme.com` |
| `bank/transfer(amount > 5000, currency = USD)` | calls where every condition matches |

- `*` matches any characters, including `/`.
- The model sees `github/create_issue` as `github__create_issue`. A pattern matches either form.
- Conditions: `=`, `!=`, `>`, `>=`, `<`, `<=`. `=` is case-insensitive and supports `*`.
- `vendor.name` is a nested argument. On a list, `lines.amount` must match every item.
- A condition on a missing argument never matches.
- Write `name = value`, not `name: value`. YAML parses `: ` as a key.

## Defaults by annotation

```yaml
allow: [write_file(notes/*)]
default:
  read_only: allow
  else: ask
```

`else` applies to tools with none of the annotations. If a tool has several, the strictest wins.

## Gated tools and content from outside

A gated tool needs approval unless a rule allows it by name. After content from outside, it needs
approval even then, unless `allow_after` lists it. See [Gated tools](/concepts/policy/#gated-tools)
and [Content from outside](/concepts/outside-content/).

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
| `timezone` | `Etc/UTC` | time zone for day, week and month boundaries; weeks start Monday |
| `grant` | one more limit | the amount an approval adds, as `{usd: 2.00}` |
| `price` | | `{input: 0.60, output: 2.20}` per million tokens, for a model with no known price |
| `on_exhausted` | `ask` | `ask` for approval, or `deny` |

- Checked before each model call. The call that crosses the limit still runs.
- Tool call costs are counted, but tool calls are never refused.
- A dollar budget refuses a model with no price unless `price` is set. `config.yaml`'s [`models`](/reference/config/#models) sets prices.
- An org's policy, set in [`orgs`](/reference/config/#orgs), has one budget shared by all its agents.
  [`GET /v1/owners/{owner}/ceilings`](/reference/http-api/#list-ceilings) returns the spend.

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
| `model` | the judge model; default `typesafe:jev-latest` |
| `questions[].question` | required; the question about the call |
| `questions[].tools` | patterns it applies to, without arguments; default: every tool |
| `questions[].deny` | deny at or above this probability (0 to 1) |
| `questions[].ask` | require approval at or above this probability |
| `questions[].allow` | allow below this probability |
| `questions[].message` | the approval or denial message, instead of the question |

- A question needs at least one of `deny`, `ask` and `allow`.
- The judge runs after the rules, and never overrides a rule's `ask` or `deny`.
- A judge's `allow` applies only to calls no rule matches, and never after content from outside.
- If the judge model fails, the call needs approval when the question has `ask` or `deny`.
- Arguments can be crafted to fool a judge. Keep exact checks in rules.
