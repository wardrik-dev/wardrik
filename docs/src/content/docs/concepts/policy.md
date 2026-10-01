---
title: Policy and approvals
description: How each tool call an agent makes is decided before it runs, how a call waits on a person, and how a budget limits what an agent spends.
sidebar:
  order: 3
---

Every tool call an agent makes is decided before it runs. It runs, it waits on a person, or it is
refused, and the model is told why. A policy is how you say which.

## Writing a policy

A policy is a file in `policies/` under the config directory:

```yaml title="~/.config/wardrik/policies/careful.yaml"
allow: [web_search, linear/*]
ask:
  github/create_*: This opens an issue on GitHub.
deny: [run_lua]
default: allow
```

An agent names it, or writes its rules in place:

```yaml
policy: careful
```

```yaml
policy:
  ask: [github/*]
  deny: [run_lua]
```

`wardrik reload` reads the policy files again, with the agent files. An agent whose policy does not
read does not read either, and one already running keeps the policy it had.

## How a call is decided

Each rule is a pattern naming tools. A tool of an MCP server is named as `server/tool`, so
`github/*` is every tool of the server `config.yaml` calls `github`. `*` stands for any run of
characters, `/` included, and is the only wildcard.

Every rule naming a call speaks for it, and the strictest decides: `deny` over `ask` over `allow`.
A call no rule names is decided by `default`, which is `allow` unless the policy says otherwise.

`allow`, `ask` and `deny` each take a list of patterns, or a map of pattern to message. A message is
what the person is asked, or what the model is told it may not do. Without one, an ask says
"github/create_issue needs your approval." and a deny "run_lua is not allowed for this agent."

The rules decide tool calls only. Every model call passes them, and a [budget](#budgets) is what
limits model calls.

### What a call acts on

A rule may name what a call acts on, in parentheses:

```yaml
allow: [write_file(notes/*)]
ask: [delete_file(*)]
```

The file tools say what their calls act on: the path, or the glob for `list_files` and
`search_files`. A deny or an ask naming what a call acts on decides it. An allow naming it lets the
call run only where the rule names everything the call acts on, and otherwise `default` decides.
Here, as in every rule, `*` matches across folders: `notes/*` names `notes/2026/10.md`.

### Without a policy

An agent with no policy may make every call its tools allow, apart from a gated tool's.

## Gated tools

Some tools are gated: a call to one waits on a person unless an `allow` rule names it.
`default: allow` is not enough, so a gated tool asks under a policy that names nothing, as it does
under none.

`config.yaml` gates an MCP server's tools with `gated`, by the names the server gives them:

```yaml
mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    gated: [create_*, issue_write]   # or true, for every tool
```

A tool written in Elixir can say it is gated too. The tools the daemon ships are not.

## Content from outside

Some tools bring in content from outside the deployment:

- `web_search` and `deep_research`;
- every MCP server `config.yaml` does not mark `trusted: true`;
- tool workers, unless `http` in `config.yaml` says `trusted_workers: true`;
- a file a turn wrote after reading content from outside, when another turn reads it.

Once a turn has read such content, a gated tool's calls wait on a person for the rest of the turn,
however the rules allow them, since what the turn read may be what asked for the call. It counts
from the next round of calls the model makes. The person is told why:

> careful allows github__create_issue, but this run has read content from outside, which may be what
> asked for it.

An agent whose job is to act on what strangers send writes `trust_outside_content: true` in its
file. Its gated calls then go ahead as its rules say, but what it writes after reading content from
outside is [marked](/concepts/files-and-memory/#content-from-outside) all the same, so another agent
that reads it is held. An agent defined over the HTTP API cannot say it.

## Waiting on a person

A call that waits on a person parks the turn. Nothing more runs, nothing is added to the
conversation, and the agent holds what it was doing until each call it waits on is decided. A
parked turn is kept in the store, so it outlives the node it parked on, and it does not time out:
an agent's `timeout` starts again when the turn carries on.

Messages that arrive meanwhile wait behind it. `POST /v1/agents/{key}/cancel`
abandons it.

In a round of several calls, the ones the rules allowed have run already. Each call that waits is
decided on its own, in any order, and the model has the round's answers once every call is decided.

### Deciding

`wardrik parked` lists what is waiting:

```
1 waiting:
  acme/triage  call_1  github/create_issue  This opens an issue on GitHub.
```

`approve` and `deny` decide one call, and `deny` takes a reason for the model:

```sh
wardrik approve acme/triage call_1
wardrik deny acme/triage call_1 Not on a Friday.
```

Without a call, they list the calls waiting and ask which, where there is someone at the terminal
to answer.

A call can also be decided:

- from Slack, where the notice shows the call's arguments, with Approve and Deny buttons. See
  [Approve calls from Slack](/guides/slack/);
- over the HTTP API, with a token that can `decide`:
  `POST /v1/agents/{key}/interrupts/{id}` with `{"decision": "approve"}`, or
  `{"decision": "reject", "reason": "..."}`;
- in the [terminal client](/guides/tui/), with Ctrl-Y and Ctrl-N.

`wardrik parked` and the HTTP API do not show a call's arguments. The Slack notice and the
[webhook](/guides/slack/#webhooks) do.

A denied tool call is answered with an error the model reads, carrying the reason, and the turn
carries on. A model call refused by a budget ends the turn.

### Changing the policy while it waits

`wardrik reload` gives a waiting agent its policy as it is now, and the new rules decide the calls
a rule asked about: a call they allow runs without a person, one they deny is refused, and one they
ask about waits on what they ask now. A gated call, and one waiting on an account to be connected,
keeps waiting.

## Budgets

A policy may hold a budget for what the agent spends on model calls, in dollars, in tokens, or
both:

```yaml
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  on_exhausted: ask   # or deny
```

- `per` is the period, `day` unless set. Days, weeks and months are UTC calendar ones, weeks from
  Monday. A `turn` budget covers one turn, with what it delegates.
- Tokens count input and output together.
- Each model call is checked against what was spent before it. The call that crosses a limit runs,
  and the next one parks, with "This agent has spent $5.02 of $5.00 today. Approve to allow $5.00
  more."
- Approving grants another limit's worth for the period, or the budget's `grant`, which takes
  `usd` and `tokens`.
- `on_exhausted: deny` ends the turn instead of asking.

Prices come from the provider where it reports what a call cost, and from the model catalog
otherwise. A dollar budget refuses every call to a model the catalog cannot price; a budget in
tokens alone governs such a model, or one a subscription pays for.

`wardrik status`, `wardrik ls` and `wardrik show` show what each agent has spent in its period.
Tool calls are not metered.

## Connecting an account

A tool that needs an account the user has not connected parks its call the same way, with a link
to authorize instead of a question, and `wardrik parked` shows the link. The call carries on by
itself once the account is connected. See [Connect accounts](/guides/accounts/).

## In Elixir

A policy is a `Wardrik.Hook`, and an application running Wardrik as a library gives an agent hooks
of its own: each is handed every tool call and model call before it happens, and may deny it, ask a
person about it, or leave it be. `WardrikPolicy.hooks/1` gives the hooks a policy written as data
is. An agent file names a hook module as its `policy`.
