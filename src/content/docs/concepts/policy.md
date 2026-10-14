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

`wardrik reload` reads policy files again, with the agent files.

| Rules that name the call | The call |
| --- | --- |
| any `deny` | is refused |
| any `ask`, no `deny` | waits for a person |
| only `allow` | runs |
| none | follows `default`, which is `allow` unless set |

## In this section

- [Writing rules](/concepts/rules/): naming calls by tool, by what they act on, and by their arguments; gated tools.
- [Approvals](/concepts/approvals/): what happens while a call waits for a person.
- [Content from outside](/concepts/outside-content/): why calls wait after an agent reads a stranger's words.
- [Budgets](/concepts/budgets/): caps on what an agent spends.
- [Judged calls](/concepts/judges/): a model's second opinion on what a call means.

Every key a policy file takes is in the [Policies reference](/reference/policies/).
