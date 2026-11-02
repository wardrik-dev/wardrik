---
title: Policy
description: "Every tool call is decided before it runs: a policy says which run, which wait for a person, and which are refused."
sidebar:
  order: 2
---

Every tool call is decided before it runs. It runs, waits for a person, or is refused. A policy
says which.

```yaml title="~/.config/wardrik/policies/careful.yaml"
allow: [web_search, linear/*]
ask:
  github/create_*: This opens an issue on GitHub.
deny: [shell/*]
```

An agent names a policy file, or writes its rules in place:

```yaml
policy: careful
```

```yaml
policy:
  ask: [github/*]
  deny: [shell/*]
```

| Rules that name the call | The call |
| --- | --- |
| any `deny` | is refused |
| any `ask` | waits for a person |
| only `allow` | runs |
| none | follows `default`, which is `allow` unless set |

- The strictest rule wins: `deny`, then `ask`, then `allow`.
- A rule's message is what the person sees, or what the model is told.
- The daemon reads `policies/` as it starts. Restart it after a change.
- An org's policy (`orgs.<org>.policy` in `config.yaml`) also holds every agent in it.

## Writing rules

- `github/*` is every tool of the MCP server named `github`.
- `*` matches anything, `/` included.
- Parentheses name what a call acts on, or conditions on its arguments.

```yaml
allow:
  - write_file(notes/*)
  - books/create_bill(amount < 100)
ask: [books/create_bill(amount >= 100)]
deny:
  email/send(to != *@example.com): Mail leaves the company only with a person's say-so.
```

- Conditions use `=`, `!=`, `>`, `>=`, `<` and `<=`. A comma means all must hold.
- A missing argument matches no condition. Name the tool in a broader rule if that matters.
- In YAML, put a rule with commas on its own line, not inside `[ ]`.

Every form is in the [Policies reference](/reference/policies/).

## Gated tools

A gated tool can change something. Its calls wait for a person unless an `allow` names them.
`default: allow` doesn't cover them.

- An MCP server's tools are gated unless the server marks them read-only. `gated:` on the server
  in `config.yaml` overrides that.
- A tool worker's tools are gated unless marked `readOnly`.
- Not gated: the file tools, `web_search`, `deep_research`, `run_lua`.
- Gated: `agent_create`, and the `agents/*` and `self/*` tools that change something.

```yaml
default: {read_only: allow, else: ask}   # decide by what a tool says of itself
```

## Judges

A judge asks a model yes-or-no questions about each call, and acts on the probability of yes.

```yaml title="~/.config/wardrik/policies/books.yaml"
judge:
  model: typesafe:jev-latest
  questions:
    - question: Does this call send money to a person or an account outside the company?
      tools: [books/*, bank/*]
      ask: 0.3
      deny: 0.9
```

| Key | When the probability is | The call |
| --- | --- | --- |
| `deny` | at or above it | is refused |
| `ask` | at or above it | waits for a person |
| `allow` | below it | is allowed |

- The judge runs after the rules. It never lifts a rule's `ask` or `deny`.
- Its `allow` holds only before the turn reads [content from outside](/concepts/outside-content/).
- Start with `ask` and `deny`. Watch real calls before you add a low `allow`.
- Give each question `tools`, or it's asked of every call.
- Set `TYPESAFE_API_KEY` for the default model.
