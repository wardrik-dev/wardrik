---
title: Policy
description: "Every tool call is decided before it runs: a policy says which run, which wait for a person, and which are refused."
sidebar:
  order: 2
  label: Overview
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
only; a [budget](/concepts/budgets/) limits model calls.

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

## More on policy

- [Approvals](/concepts/approvals/): what happens while a call waits for a person.
- [Content from outside](/concepts/outside-content/): why calls wait after an agent reads a stranger's words.
- [Budgets](/concepts/budgets/): caps on what an agent spends.
- [Judged calls](/concepts/judges/): a model's second opinion on what a call means.

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

### Policy files and reload

An agent whose policy doesn't read doesn't read either; one already running keeps the policy it
had.

### In Elixir

A policy is a `Wardrik.Hook`. An application using Wardrik as a library can give an agent its own
hooks: each sees every tool call and model call first, and can deny it, ask a person, or let it
run. `WardrikPolicy.hooks/1` turns a policy written as data into hooks, and an agent file can name a
hook module as its `policy`. A tool written in Elixir can declare itself gated.
