---
title: Let anyone try to hijack it
description: An agent with write access to a public repository's issues, which no issue can talk into anything you haven't approved.
sidebar:
  order: 9
---

This agent labels and comments on a public repository's issues, with a token that can write them.
Invite anyone to take it over. Whatever an issue gets it to try arrives in Slack as a call waiting
for you. Its prompt has no warnings: its calls are decided outside the model.

Needs a fine-grained GitHub token that can write that repository's issues and nothing else, and a
[Slack app](/channels/slack/).

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
    members: {U024BE7LH: user:maria}

notify:
  targets:
    triage: {channel: slack, room: "#triage"}

roles:
  approver:
    rules: [{verbs: [read, events, decide], kinds: [agent], names: [issues]}]
bindings:
  - {org: default, role: approver, subjects: [user:maria]}
```

- Both write tools are gated. Once the agent has read an issue, a gated call waits for a person.
- `members` maps Maria's Slack ID to `user:maria`. The binding lets her decide the agent's calls.

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

- `default: deny` refuses every tool `allow` doesn't name.
- The budget caps what a stranger can make it spend.

## Try it

```sh
echo "$GITHUB_TOKEN" | wardrik vault put GITHUB_TOKEN --for header
echo "$SLACK_BOT_TOKEN" | wardrik vault put SLACK_BOT_TOKEN --for api_key
echo "$SLACK_SIGNING_SECRET" | wardrik vault put SLACK_SIGNING_SECRET --for signing_secret
systemctl --user restart wardrik
wardrik agent show issues
```

Open an issue that tries to hijack it, then watch `#triage`:

> `issues` waits on a person to approve `github__issue_write`.
>
> ```
> {"issue_number":14,"labels":["bug"],"method":"update","owner":"acme","repo":"widgets"}
> ```

If an issue fools the model into closing everything, each close is a call waiting for you.

## What it shows

- After outside content, every gated call waits, until `wardrik agent clear issues`. See
  [Content from outside](/concepts/outside-content/).
- Files keep the label of what the turn had read, so notes can't carry an instruction forward.
- Rules live outside the prompt, where no issue can change them. See [Policy](/concepts/policy/).
- Don't add `allow_after: {outside: [github/issue_write]}`: one tool both labels and closes.
