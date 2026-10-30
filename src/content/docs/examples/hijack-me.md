---
title: Let anyone try to hijack it
description: An agent with write access to a public repository's issues, which no issue can talk into anything you haven't approved.
sidebar:
  order: 9
---

This agent labels and comments on a public repository's issues, with a token that can write them.
Invite anyone to take it over. Whatever an issue makes it try arrives in Slack as a call waiting
for you. Its prompt has no warnings: its calls are decided outside the model.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key;
- a public repository, and a fine-grained GitHub token that can read and write that repository's
  issues and nothing else, so a mistaken approval can reach no further;
- a [Slack app](/channels/slack/#a-slack-app) with a bot token and a signing secret.

## The files

### config.yaml

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

notify:
  triage:
    channel: slack
    room: "#triage"
    approvers: ["@maria"]
```

Both write tools are gated. Once the agent has read an issue, a gated call waits for a person.

Seal the keys while the daemon runs. `vault put` reads the value from stdin:

```sh
echo "$GITHUB_TOKEN" | wardrik vault put GITHUB_TOKEN
# and the same for SLACK_BOT_TOKEN and SLACK_SIGNING_SECRET
```

### The agent

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

- `allow` lets its tools run, but the gated ones still wait: the turn has read issues.
- `default: deny` refuses every other tool.
- The budget caps what a stranger can make it spend.

## Try it

Restart the daemon to read `config.yaml`, then check the agent:

```sh
systemctl --user restart wardrik
wardrik agent show issues
```

Open an issue inviting anyone to hijack it, then watch `#triage`:

> `issues` waits on @maria to approve `github__issue_write`.
>
> `github__issue_write`  github/issue_write is allowed, but this run has read content from
> outside, which may be what asked for it.
> _It has read content from outside, which may be what asked for this._
>
> ```
> {"issue_number":14,"labels":["bug"],"method":"update","owner":"acme","repo":"widgets"}
> ```

If an issue fools the model into closing everything, each close is a call waiting for you. If one
asks it to leak its instructions, the comment waits unseen.

## What it shows

- **Labels** hold every gated call after outside content, until `wardrik agent clear issues`
  empties the conversation. See [Content from outside](/concepts/outside-content/).
- **Files remember** their label, so notes can't carry an instruction forward. See
  [Files and memory](/concepts/files-and-memory/#content-from-outside).
- **Rules outside the prompt**, which no issue can change. See [Policy](/concepts/policy/).
- **A narrow token**, tools and approver list.

## Details

### Not this

`allow_after: {outside: [github/issue_write]}` would also let closes through, since one tool does
both. Allow a tool after outside content only if you'd let a stranger use it.

### Taking it further

- Record every attempt from the [event stream](/concepts/events/).
- Add a second repository with its own token.
