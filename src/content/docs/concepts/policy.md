---
title: Policy
description: "A policy defines which tool calls run, which need approval, and which are denied."
sidebar:
  order: 2
---

A policy defines whether each tool call runs, needs approval, or is denied. It's checked before
the call runs.

```yaml title="~/.config/wardrik/policies/careful.yaml"
allow: [web_search, linear/*]
ask:
  github/create_*: This opens an issue on GitHub.
deny: [shell/*]
```

Set an agent's `policy` to a file name, or write the rules inline:

```yaml
policy: careful
```

```yaml
policy:
  ask: [github/*]
  deny: [shell/*]
```

| Rules matching the call | Result |
| --- | --- |
| any `deny` | denied |
| any `ask` | needs approval |
| only `allow` | runs |
| none | `default`, which is `allow` unless set |

- The strictest rule wins: `deny`, then `ask`, then `allow`.
- A rule's message is shown to the approver, or returned to the model on a denial.
- The daemon reads `policies/` at startup. Restart it after a change.
- An org's policy (`orgs.<org>.policy` in `config.yaml`) also applies to every agent in the org.

## Writing rules

- `github/*` matches every tool of the MCP server named `github`.
- `*` matches any characters, including `/`.
- Parentheses match a call's target or its arguments.

```yaml
allow:
  - write_file(notes/*)
  - books/create_bill(amount < 100)
ask: [books/create_bill(amount >= 100)]
deny:
  email/send(to != *@example.com): Mail leaves the company only with a person's say-so.
```

- In YAML, put a rule with commas on its own line, not inside `[ ]`.

Every operator and pattern form is in [Policies › Patterns](/reference/policies/#patterns).

## Gated tools

A gated tool can change something. Its calls need approval unless an `allow` rule matches them.
`default: allow` doesn't apply to them.

- An MCP server's tools are gated unless the server marks them read-only. Set `gated:` on the
  server in `config.yaml` to override.
- A tool worker's tools are gated unless marked `readOnly`.
- Not gated: the file tools, `web_search`, `deep_research`, `run_lua`.
- Gated: `agent_create`, and the `agents/*` and `self/*` tools that change something.

```yaml
default: {read_only: allow, else: ask}   # by the tool's own read-only flag
```

## Judges

A judge asks a model yes-or-no questions about each call. The probability of yes sets the result.

```yaml title="~/.config/wardrik/policies/books.yaml"
judge:
  model: typesafe:jev-latest
  questions:
    - question: Does this call send money to a person or an account outside the company?
      tools: [books/*, bank/*]
      ask: 0.3
      deny: 0.9
```

- `deny` and `ask` apply at or above their probability. `allow` applies below it.
- Start with `ask` and `deny`. Review real calls before you add a low `allow`.
- Set `TYPESAFE_API_KEY` for the default model.

Every judge key is in [Policies › Judges](/reference/policies/#judges).
