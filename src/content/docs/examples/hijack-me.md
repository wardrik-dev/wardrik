---
title: Let anyone try to hijack it
description: An agent with write access to a public repository's issues. No issue can trigger a write you haven't approved.
sidebar:
  order: 9
---

This agent labels and comments on a public repository's issues, with a token that has write access.
Anyone can try prompt injection. Every write it attempts is posted to Slack for approval. The
prompt has no warnings, because the policy is enforced outside the model.

Requires a fine-grained GitHub token with write access to that repository's issues only, and a
[Slack app](/build/slack/).

## The files

```yaml title="~/.config/wardrik/config.yaml"
mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    headers:
      authorization: Bearer ${GITHUB_TOKEN}
    only: [list_issues, search_issues, issue_read, issue_write, add_issue_comment]
    gated: [issue_write, add_issue_comment]

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    domains: {acme.com: default}

notify:
  targets:
    triage: {channel: slack, room: "#triage"}

roles:
  approver:
    rules: [{verbs: [read, events, decide], kinds: [agent], names: [issues]}]
bindings:
  - {org: default, role: approver, subjects: [user:default/@maria]}
```

- Both write tools are gated. After the agent reads an issue, gated calls need approval.
- `domains` makes `maria@acme.com` in Slack the user `user:default/@maria`. The binding allows
  that user to approve the agent's calls.

```markdown title="~/.config/wardrik/agents/issues.md"
---
description: Triages the issues anyone files on acme/widgets.
model: anthropic:claude-sonnet-5
tools: [github/*, files]
context: [TRIAGE.md]
triggers:
  - name: sweep
    every: 15m
    prompt: Triage the issues opened since your last sweep.
policy:
  allow: [github/*, read_file, write_file(TRIAGE.md), edit_file(TRIAGE.md)]
  default: deny
  budget: {usd: 3.00, per: day, on_exhausted: deny}
notify: triage
---
You triage the issues filed on github.com/acme/widgets.

For each issue opened since your last sweep, label it bug, feature or question, and comment on it:
thank whoever filed it, and say what you would need from them to act on it. Keep the number of the
last issue you triaged in TRIAGE.md.
```

- `default: deny` denies every tool not matched by `allow`.
- The budget caps the spend an attacker can cause.

## Try it

```sh
echo "$GITHUB_TOKEN" | wardrik vault put GITHUB_TOKEN --for header
echo "$SLACK_BOT_TOKEN" | wardrik vault put SLACK_BOT_TOKEN --for api_key
echo "$SLACK_SIGNING_SECRET" | wardrik vault put SLACK_SIGNING_SECRET --for signing_secret
systemctl --user restart wardrik
wardrik agent show issues
```

Open an issue with a prompt injection, then watch `#triage`:

> `issues` waits on a person to approve `github__issue_write`.
>
> ```
> {"issue_number":14,"labels":["bug"],"method":"update","owner":"acme","repo":"widgets"}
> ```

If an injection makes the model try to close every issue, each close is a pending call.

## What it shows

- After content from outside, every gated call needs approval until `wardrik agent clear issues`.
  See [Content from outside](/concepts/outside-content/).
- Files written in the turn get the `outside` label, so notes can't pass an injection to a later
  turn.
- The policy is defined outside the prompt, so no issue can change it. See [Policy](/concepts/policy/).
- Don't add `allow_after: {outside: [github/issue_write]}`. The same tool both labels and closes.
