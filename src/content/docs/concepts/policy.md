---
title: Policy
description: "Every tool call is decided before it runs: a policy says which run, which wait for a person, and which are refused."
sidebar:
  order: 2
  label: Overview
---

Every tool call an agent makes is decided before it runs. It runs, it waits for a person, or it is
refused, and the model is told why. A policy says which.

```yaml title="~/.config/wardrik/policies/careful.yaml"
allow: [web_search, linear/*]
ask:
  github/create_*: This opens an issue on GitHub.
deny: [shell/*]
```

An agent names the file, or writes its rules in place:

```yaml
policy: careful
```

```yaml
policy:
  ask: [github/*]
  deny: [shell/*]
```

The daemon reads `policies/` as it starts. Restart it after you change a policy file.

| Rules that name the call | The call |
| --- | --- |
| any `deny` | is refused |
| any `ask`, no `deny` | waits for a person |
| only `allow` | runs |
| none | follows `default`, which is `allow` unless set |

A call to a [gated](/concepts/rules/#gated-tools) tool that no rule allows waits for a person,
whatever `default` says. An agent is also held to its
[org's policy](/run/orgs/#hold-an-org-to-a-policy), and the strictest decision wins.

## In this section

- [Writing rules](/concepts/rules/): naming calls by tool, by what they act on, and by their
  arguments; gated tools.
- [Approvals](/concepts/approvals/): what happens while a call waits for a person.
- [Content from outside](/concepts/outside-content/): why calls wait after an agent reads a
  stranger's words.
- [Budgets](/concepts/budgets/): caps on what an agent spends.
- [Judged calls](/concepts/judges/): a model's second opinion on what a call means.

Every key a policy file takes is in the [Policies reference](/reference/policies/).
