---
title: An agent that acts on what it notices
description: An agent that hears when a competitor moves, does the work that follows, and proposes the rest as calls the team approves in Slack.
sidebar:
  order: 3
---

This agent doesn't just report a competitor's launch. It drafts your response and proposes next
steps as the tool calls that would do them: an issue, a draft campaign, a budget change.

The team approves or denies each call in Slack. Research and drafts run alone; anything leaving the
deployment waits. A budget caps its daily spend.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key from the
  [Quickstart](/getting-started/quickstart/);
- a key for `web_search`;
- GitHub's MCP server, with a token for a machine account that can read the repository and open
  issues;
- an app of your own offering the ad platform's tools, with the
  [TypeScript SDK](/build/tool-workers/). Any service with an MCP server works the same way;
- a [Slack app](/channels/slack/#a-slack-app) and a channel for it, here `#growth`.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
org: acme

mcp:
  github:
    url: https://api.githubcopilot.com/mcp/
    headers:
      authorization: Bearer ${GITHUB_TOKEN}
    only: [get_file_contents, search_code, search_issues, issue_write]
    gated: [issue_write]

tools:
  web_search:
    price: 0.005

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
    approvers: ["@maria", "@sam"]

notify:
  growth:
    channel: slack
    room: "#growth"
    approvers: ["@maria", "@sam"]
```

- `only` limits GitHub to reading and `issue_write`, so nothing it reads can get it to push, merge
  or close.
- `gated` makes `issue_write` wait on a person unless a rule allows it by name.
- `tools` prices `web_search`, so the budget counts searching.
- `approvers` are who may press Approve and Deny. See [Who approves](/channels/slack/#who-approves).

Restart the daemon and check the server:

```sh
systemctl --user restart wardrik
wardrik doctor
```

### The ad platform's tools

Your app offers them and runs them, with your keys. Here `ads` stands for the platform's client:

```ts title="growth.ts"
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";

const wardrik = new Wardrik({ name: "growth" });

wardrik.tool({
  name: "list_campaigns",
  description: "List our campaigns, with what each spends a day and how it performs.",
  input: z.object({}),
  readOnly: true,
  run: () => ads.campaigns.list(),
});

wardrik.tool({
  name: "keyword_volume",
  description: "How often each keyword is searched a month, and what a click costs.",
  input: z.object({ keywords: z.array(z.string()).max(20) }),
  readOnly: true,
  run: async ({ keywords }, { cost }) => {
    const volumes = await ads.keywords.volume(keywords);
    cost(0.02 * keywords.length);
    return volumes;
  },
});

wardrik.tool({
  name: "create_draft_campaign",
  description: "Create a campaign with one ad, paused, so it spends nothing until it is launched.",
  input: z.object({
    name: z.string(),
    headline: z.string(),
    body: z.string(),
    keywords: z.array(z.string()),
  }),
  idempotent: true,
  run: (campaign, { idempotencyKey }) =>
    ads.campaigns.create({ ...campaign, status: "paused" }, { idempotencyKey }),
});

wardrik.tool({
  name: "update_campaign",
  description: "Launch or pause a campaign, or change what it may spend a day, in US dollars.",
  input: z.object({
    campaign_id: z.string(),
    status: z.enum(["active", "paused"]).optional(),
    daily_budget: z.number().optional(),
  }),
  idempotent: true,
  run: ({ campaign_id, ...change }, { idempotencyKey }) =>
    ads.campaigns.update(campaign_id, change, { idempotencyKey }),
});

await wardrik.work();
```

- `readOnly` tools change nothing. The other two are [gated](/concepts/rules/#gated-tools): each
  call waits on a person unless a rule allows it by name.
- `cost` reports what the paid keyword API charged; the budget counts it. See
  [What a call cost](/build/tool-workers/#what-a-call-cost).
- `idempotencyKey` goes to the platform, so a call run again after a lost node changes nothing
  twice.

Start it with a token that can serve acme's agents:

```sh
wardrik token create growth --scope acme/ --can serve
WARDRIK_TOKEN=wardrik_... node growth.ts
```

### The policy

```yaml title="~/.config/wardrik/policies/growth.yaml"
allow:
  - web_search
  - read_file
  - list_files
  - search_files
  - write_file
  - edit_file
  - github/get_file_contents
  - github/search_*
  - workers/list_campaigns
  - workers/keyword_volume
allow_after:
  outside:
    - workers/create_draft_campaign
ask:
  github/issue_write: This opens or changes an issue on GitHub.
  workers/update_campaign: This changes a live campaign, and what it spends.
deny:
  delete_file(*): Keep what you have written.
  workers/update_campaign(daily_budget > 200): A campaign over $200 a day goes through the marketing lead.
default: ask
budget:
  usd: 10.00
  per: day
  on_exhausted: ask
```

- **Research and drafts run alone.** A draft in the team's shared tree stays a draft until someone
  publishes it.
- **What leaves the deployment waits.** A person sees the message and the arguments.
- **A paused draft needs nobody.** Feeds are outside content, so gated calls wait however `allow`
  names them. `allow_after` still allows the draft: the worst a stranger causes is a draft nobody
  launches. See [After content from outside](/reference/policies/#after-content-from-outside).
- **Over $200 a day is refused.** A call without `daily_budget` still asks. See
  [Conditions on arguments](/reference/policies/#conditions-on-arguments).
- **Anything unnamed asks**, including a tool added later.
- **$10 a day,** counting model calls, priced searches and reported costs. Then the next model call
  waits in `#growth` for another $10. See [Budgets](/reference/policies/#budgets).

### The agent

```markdown title="~/.config/wardrik/agents/growth.md"
---
description: Hears when a competitor moves, does what follows, and proposes the rest as calls.
model: anthropic:claude-sonnet-5
tools: [web_search, files, github/*, workers/*]
workspace:
  shared:
    team: acme
context: [WATCHLIST.md, DECISIONS.md]
policy: growth
timeout: 900
channels: [slack]
triggers:
  - name: launches
    every: 30m
    feed:
      - https://rivalco.example/changelog.rss
      - https://billwise.example/blog/atom.xml
      - https://www.google.com/alerts/feeds/0123456789/0123456789
    prompt: New from the competitors you watch, below.
  - name: sweep
    every: "0 8 * * 1"        # 08:00 UTC on Mondays
    prompt_file: HEARTBEAT.md
notify: {to: [growth], on: [parked, failed, finished]}
---
You look out for Acme, invoicing software for small agencies, and act on what our competitors do.
WATCHLIST.md says who they are and what matters about each. HEARTBEAT.md is your checklist for the
Monday sweep, of what has no feed, such as pricing pages. Keep both current.

When a competitor launches, prices or announces something that matters, do the work that follows
without waiting to be asked:

1. Find out what it is and who it is for, from their pages and from what people say about it.
2. Find its weak points: what it leaves out, what it costs, who it does not suit, and where we are
   stronger. Search our code in acme/app before you say we do something.
3. Draft our response in shared/team/responses/, a file per launch: a positioning note for sales,
   a post for our blog, and an email to the customers it might tempt.
4. Propose what should happen next, by making the calls that would do it: an issue in acme/app for
   the feature that answers theirs, saying what it should do and why now; a draft campaign that
   speaks to the weak points you found, with keywords whose volume you checked; and the change to a
   campaign that launches it, or moves budget to it.

Never write a next step as a suggestion. When something should be done and one of your tools does
it, call the tool with the arguments you would want run: the team sees the call in #growth, and
approving it runs it as you wrote it. Make the calls for one launch together where you can, so they
are decided side by side, and make no more than the launch calls for.

A denied call comes back with the reason. Do not make it again. Write it in DECISIONS.md with the
reason, and what the team approved too, and let what they decided shape what you propose next.

Answer with a brief: what happened, its weak points, where the drafts are, and what you proposed.
If nothing matters, answer "Nothing worth acting on." in one line.
```

- `feed` checks every half hour and asks only about new entries. A run while it waits on a person
  skips; the next run finds the same entries. See [Watching a feed](/build/triggers/#watching-a-feed).
- `prompt_file` has it follow `HEARTBEAT.md` each Monday, a checklist it edits itself. See
  [A checklist the agent can edit](/build/triggers/#a-checklist-the-agent-can-edit).
- `workspace` shares acme's tree as `shared/team/`, where the team and its other agents read the
  drafts.
- `context` reads both files into every turn, so past decisions shape new proposals.
- `notify` posts to `#growth` what each run waits on and answers. `channels` lets the team reply in
  Slack.

Step 4 makes it act rather than report: a waiting call is the work, held until someone says yes.

## Try it

Read the files again, tell it who to watch, and hand it a launch:

```sh
wardrik reload
wardrik ask growth "Our competitors are Rivalco (rivalco.com) and Billwise (billwise.io).
Write WATCHLIST.md with what matters about each, and a HEARTBEAT.md for your Monday sweeps."
wardrik ask growth "Rivalco launched a free plan for teams of up to three today, at
rivalco.com/pricing. Do what you would do."
```

The second runs until it waits on the team. Its calls and its brief land in `#growth`. Invite the
app with `/invite @yourapp`, then reply under a brief, mentioning the app, to ask about it or redirect
it; see [Threads in Slack](/channels/slack/#threads-in-slack).

The `launches` trigger's first run only notes what the feeds hold, so its first brief comes with the
next new entry.

## What it shows

- **Next steps as calls.** Approving does the work; denying teaches why.
- **Runs or waits.** Named approvers decide what leaves the deployment. See
  [Policy and approvals](/concepts/policy/).
- **Rules that know what it read.** After outside content, only `allow_after` tools skip a person.
- **One budget** over models, priced tools and reported costs.
- **Memory of decisions,** in a file read every turn.
- **A record** of every call, its decider and its cost.

## Details

### Deciding a proposal

`#growth` shows each call with its tool, the policy's message, that the run read outside content,
and its arguments. Any approver decides each call on its own, in any order.

- **Approve** runs the call as written. A note above the buttons reaches the agent beside the
  answer; it can't change the call.
- **Deny** refuses it with a reason: "Denied in Slack by maria: We are not competing on price." To
  change a call, deny it and say what to do instead.

Once every call is decided, the run carries on, records the decisions in `DECISIONS.md`, and posts
its brief. Allowed calls, such as the draft campaign, already ran. From a terminal, `wardrik parked`,
`wardrik approve` and `wardrik deny` do the same, with a note or a reason. See
[Waiting on a person](/concepts/approvals/).

### Another signal: a webhook

A `webhook` trigger asks whenever a service sends something, here a CRM reporting a lost deal:

```yaml
triggers:
  - name: lost-deal
    webhook:
      secret: ${CRM_HOOK_SECRET}
    prompt: >
      A deal was lost; the CRM's event is below. If it went to a competitor, find out why, and act
      on it as you would on a launch. Otherwise answer in one line.
```

Seal the secret with `wardrik vault put CRM_HOOK_SECRET --org acme`. Give the CRM the address
`wardrik triggers` prints; the CRM must be able to reach it. What a service sends is outside
content, like a feed. See [Receiving a webhook](/build/triggers/#receiving-a-webhook).

### Letting it choose what it watches

With `self/*` in its tools, the agent can read its definition and set or remove its own triggers.
Each change is a gated call, proposed and approved like any other:

```yaml title="~/.config/wardrik/policies/growth.yaml"
allow:
  # ...the rules above, and:
  - agent_definition_read
ask:
  # ...the rules above, and:
  agent_trigger_set: This changes what it watches.
  agent_trigger_remove: This stops one of its triggers.
```

A file's agent keeps the file's triggers, so define this one over the HTTP API. Remove `growth.md`
from `agents/` and run `wardrik reload`; the agent stops, keeping its conversation. Save the file's
body as `instructions.md` and define it with a token held to the policy:

```sh
wardrik token create growth-admin --scope acme/ --can define --policy growth
export TOKEN=wardrik_...

jq -n --rawfile instructions instructions.md '{
  description: "Hears when a competitor moves, does what follows, and proposes the rest as calls.",
  instructions: $instructions,
  model: "anthropic:claude-sonnet-5",
  tools: ["web_search", "files", "github/*", "workers/*", "self/*"],
  workspace: {shared: {team: "acme"}},
  context: ["WATCHLIST.md", "DECISIONS.md"],
  policy: "growth",
  timeout: 900,
  channels: ["slack"],
  triggers: [
    {name: "launches", every: "30m", prompt: "New from the competitors you watch, below.",
     feed: ["https://rivalco.example/changelog.rss", "https://billwise.example/blog/atom.xml",
            "https://www.google.com/alerts/feeds/0123456789/0123456789"]},
    {name: "sweep", every: "0 8 * * 1", prompt_file: "HEARTBEAT.md"}
  ]
}' | curl -X PUT -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/growth -d @-
```

Add a line to its instructions, such as "When you find a feed worth watching, set a trigger for it;
when one has told you nothing worth acting on for a month, remove it." The team can also ask in
`#growth`:

> **maria:** @Wardrik Billwise has a changelog feed now, billwise.example/changelog.rss. Watch it.
> ↳ **Wardrik:** Waiting on @maria or @sam to approve `agent_trigger_set`.

Approved, `wardrik triggers` lists the trigger and `wardrik audit` records the agent as its setter.
A definition sent over HTTP has no `notify`, so its triggered runs post nothing to `#growth`; use
`wardrik parked`, the [terminal client](/build/tui/) or the HTTP API. Slack threads still ask the
approvers.

### Steering it in a thread

Reply under anything it posted, and it answers in the thread. Tell it what you want more or less
of, and it edits the files it works from, so every later run follows:

> **maria:** Stop following their hiring. Look at their pricing page every Monday instead.
> ↳ **Wardrik:** Done. I took hiring out of WATCHLIST.md, and HEARTBEAT.md now checks
> rivalco.com/pricing on Mondays.

Threads share the agent's files. See [Threads in Slack](/channels/slack/#threads-in-slack) and
[A checklist the agent can edit](/build/triggers/#a-checklist-the-agent-can-edit).

### A record of what it did

Every message, call, decision and refusal is an event:

- `tool_call.started` says who let a call run, a person or the policy;
- `interrupt.resolved` says who approved or denied it, and what they wrote;
- `tool_call.denied` says why a rule refused it;
- `tool_call.completed` says what it cost.

`wardrik watch growth --json` follows them, one a line. `wardrik audit` lists changes and who made
them: an agent defined, a trigger set, a token made. `wardrik show growth` shows what it has spent
this period. See [The event stream](/concepts/events/).

### Trusting it with more

Start with every outside effect asking. Loosen where the team approves the same call every time.
These rules let it launch campaigns up to $50 a day alone; bigger ones ask, and over $200 is refused:

```yaml title="~/.config/wardrik/policies/growth.yaml"
allow_after:
  outside:
    - workers/create_draft_campaign
    - workers/update_campaign(daily_budget <= 50)
ask:
  github/issue_write: This opens or changes an issue on GitHub.
  workers/update_campaign(daily_budget > 50): This spends more than $50 a day.
deny:
  delete_file(*): Keep what you have written.
  workers/update_campaign(daily_budget > 200): A campaign over $200 a day goes through the marketing lead.
```

The rest of the policy stays as it was. The `ask` rule names only calls over $50, because an ask
beats an `allow_after` naming the same call. A call with no `daily_budget`, such as a plain launch
or pause, matches neither, so it waits as a gated call does. `wardrik reload` applies the rules to
the running agent, and a waiting call they now allow runs. See
[Changing the policy while it waits](/concepts/approvals/#changing-the-policy-while-it-waits).

As it gets more rope:

- **Allow after outside only what a stranger can't turn against you.** A paused draft or a capped
  budget does bounded harm; a post in your name does not.
- **The budget counts the agent's spending, not its campaigns'.** Cap ad spend with argument rules
  and the platform's own limits.
- **Rules decide exact matters.** For what a call means, such as whether a post makes a claim about
  a competitor, a [judge](/reference/policies/#judges) can ask a person.

### Taking it further

- **Pull requests.** Give the GitHub server tools to branch, push and open pull requests. Allow
  pushing to its own branches under `allow_after`, with an argument rule, so only the pull request
  waits. Do so only where pushing a branch runs nothing with your secrets.
- **Where people talk about you.** Add a feed of a Google Alert or a Reddit search, and have it
  propose replies where your tools can post them.
