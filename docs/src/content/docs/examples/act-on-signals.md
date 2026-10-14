---
title: An agent that acts on what it notices
description: An agent that hears when a competitor moves, does the work that follows on its own, and proposes the rest as tool calls the team approves in Slack, which run as they are approved, all within a policy and a budget.
sidebar:
  order: 7
---

Most agents that watch something report what they saw, and leave the rest to whoever reads it. This
one carries on. When a competitor launches something, it works out what the launch means for you,
finds where it is weak, drafts your response, and then proposes what should happen next: an issue
for the feature that answers it, a campaign aimed at what the competitor left out, a change to what
a campaign spends.

Each proposal is the tool call that would do it. The team sees the call in Slack, with its
arguments, and approves it, and it runs as the agent wrote it; or denies it with a reason, which the
agent reads and remembers. Nobody has to turn a suggestion into work.

The policy says what it may do on its own and what waits on a person. Here research, reading and
drafts in its own files run freely; whatever leaves the deployment, an issue, a campaign, money
spent, waits. A budget caps what it spends in a day, model calls and paid tools together.

## What it takes

- the daemon, [installed](/getting-started/install/) and running, with a model provider's key as the
  [Quickstart](/getting-started/quickstart/#set-it-up) gives it one;
- a key for `web_search`, where the daemon reads its keys;
- an MCP server for wherever the team tracks its work, here GitHub's, with a token for a machine
  account that can read the repository and open issues in it;
- the services it should act on, here an ad platform, offered as tools by an app of your own; see
  [Tools in your app](/build/tool-workers/). Any service with an MCP server works the same way;
- a Slack app with a bot token and an app-level token, made as
  [Slack](/channels/slack/#a-slack-app) makes one, and a Slack channel for it, here `#growth`.

## The server and the channel

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

- `only` gives the agent GitHub's tools for reading code and issues, and `issue_write`, and no
  others, so nothing it reads can get it to push, merge or close anything.
- `gated` makes `issue_write` wait on a person unless a rule allows it by name.
- `tools` prices each `web_search` call, so the budget counts what searching costs.
- `approvers` are who may approve: in `#growth`, where the agent's triggered runs ask, and in the
  app's messages with them, where a thread's conversation asks. Anyone else who presses a button is
  told only the approvers can answer. See [Who approves](/channels/slack/#who-approves).

Restart the daemon after changing `config.yaml`, and check the server:

```sh
systemctl --user restart wardrik
wardrik doctor
```

## Tools that act

An app of your own offers the agent the ad platform's tools, with the
[TypeScript SDK](/build/tool-workers/). It runs in your process with your keys; here `ads` stands
for the platform's client:

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

- `readOnly` marks the tools that change nothing. The other two are
  [gated](/concepts/policy/#gated-tools): each call waits on a person unless a rule allows it by
  name.
- `cost` says what a call to the paid keyword API cost, which the agent's budget counts. See
  [What a call cost](/build/tool-workers/#what-a-call-cost).
- `idempotencyKey` passes the daemon's key for each call on to the platform, so a call the daemon
  runs again, after a node is lost, changes nothing twice.

Give it a token that can offer tools to acme's agents, and start it:

```sh
wardrik token create growth --scope acme/ --can serve
WARDRIK_TOKEN=wardrik_... node growth.ts
```

## The policy

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

What it may do alone, what waits, and what it may not do at all:

- **Research and drafts run on their own.** Searching, reading code and campaigns, and writing its
  own files are allowed by name. The file tools reach its own tree and the trees it shares, so a
  draft written to the team's shared tree is a draft, which someone still has to publish.
- **What leaves the deployment waits.** Opening an issue and changing a campaign ask a person, who
  is shown the message beside the call and its arguments.
- **A paused campaign is made without asking.** The agent reads content from outside on every run,
  feeds and search results that anyone could have written, so its turns carry the `outside` label,
  and once they do, `allow` stops counting for a gated tool: each call waits on a person, since
  what the agent read may be what asked for it. `allow_after` allows a tool by name even then. It
  suits `create_draft_campaign`, which spends nothing and shows nothing to anyone, so the worst a
  stranger's words can do is a draft nobody launches. See
  [Allowing after content from outside](/concepts/policy/#allowing-after-content-from-outside).
- **Some calls are refused outright.** A deny rule can say what a call's arguments must not be:
  `daily_budget > 200` refuses a campaign over $200 a day, and tells the agent why. A call that
  leaves `daily_budget` out still asks, under the `ask` rule. See
  [What a call's arguments are](/concepts/policy/#what-a-calls-arguments-are).
- **Whatever no rule names asks.** `default: ask` holds a tool added next month, until a rule
  names it.
- **The budget is $10 a day.** It counts every model call, each `web_search` at the price
  `config.yaml` lists, and what `keyword_volume` reports. Once it is spent, the next model call
  waits in `#growth` for someone to allow another $10. See [Budgets](/concepts/policy/#budgets).

## The agent

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

- `feed` reads the feeds every half hour, and asks the agent only when one has entries it has not
  seen, with them under the prompt. A run while the agent waits on a person lets it be, and the
  next run finds the same entries. See [Watching a feed](/build/triggers/#watching-a-feed).
- `prompt_file` asks it each Monday to follow `HEARTBEAT.md`, a checklist it edits itself. See
  [A checklist the agent can edit](/build/triggers/#a-checklist-the-agent-can-edit).
- `workspace` shares acme's tree with it as `shared/team/`, where the team reads its drafts and
  the team's other agents can too.
- `context` reads `WATCHLIST.md` and `DECISIONS.md` into every turn, so what the team approved and
  denied is in front of it each time it proposes.
- `notify` posts to `#growth` what each run waits on, with Approve and Deny, and what each run
  answers. `channels` offers it in Slack, so the team can reply under a brief and talk it over.

## Proposals as calls

The instructions' fourth step is what makes it act rather than report. A suggestion written in a
brief needs someone to go and do it; a call that waits on a person is the doing, held until
someone says yes. So the agent is told to propose by calling.

When a run proposes, it parks, and `#growth` gets the calls it waits on: for each its tool, what the
policy asks, that the run had read content from outside, and its arguments, such as the issue's
title and body or the campaign's budget, with Approve and Deny. Each call is decided on its own,
in any order, by any of the approvers:

- **Approve** runs the call with the arguments the agent wrote. A note typed above the buttons goes
  to the agent beside the call's answer, to steer what it does next; it cannot change the call.
- **Deny** refuses it, and the agent reads why: "Denied in Slack by maria: We are not competing on
  price." To change a call, deny it and say what to do instead, and the agent can make it again as
  asked.

Once every call is decided, the run carries on with their answers, writes what was decided to
`DECISIONS.md`, and posts its brief. Calls the policy allowed, such as the draft campaign, ran
already. See [Waiting on a person](/concepts/policy/#waiting-on-a-person).

The same holds from a terminal: `wardrik parked` lists what waits, and `wardrik approve` and
`wardrik deny` decide it, with a note or a reason.

## Try it

Read the agent files again, tell it who to watch, and hand it a launch:

```sh
wardrik reload
wardrik ask growth "Our competitors are Rivalco (rivalco.com) and Billwise (billwise.io).
Write WATCHLIST.md with what matters about each, and a HEARTBEAT.md for your Monday sweeps."
wardrik ask growth "Rivalco launched a free plan for teams of up to three today, at
rivalco.com/pricing. Do what you would do."
```

The second runs until it waits on the team, and its calls are in `#growth`. Each answer is posted
there too. Invite the app to `#growth`, `/invite @yourapp`, and the team can reply under a brief,
mentioning the app, to ask about it or tell the agent what to do instead; see
[Threads in Slack](/channels/slack/#threads-in-slack). The launches trigger's first run only notes what the feeds already hold, so its first
brief comes with the next entry one of them adds.

## Other signals

A trigger on a clock alone asks on a schedule, and a `webhook` trigger asks whenever a service
sends it something. Here, one added to its triggers, for a CRM that calls when a deal is lost:

```yaml
triggers:
  - name: lost-deal
    webhook:
      secret: ${CRM_HOOK_SECRET}
    prompt: >
      A deal was lost; the CRM's event is below. If it went to a competitor, find out why, and act
      on it as you would on a launch. Otherwise answer in one line.
```

Seal the secret for the org with `wardrik vault put CRM_HOOK_SECRET --org acme`, and give the CRM the
address `wardrik triggers` prints, which must be reachable from it. What a service sends is content
from outside, as a feed's entries are. See [Receiving a webhook](/build/triggers/#receiving-a-webhook).

## Letting it choose what it watches

`self/*` in its tools lets an agent read its own definition, and set and remove its own triggers:
add a feed it found, or drop one that never says anything worth acting on. Each change is a gated
call too, proposed and approved like any other. The tools are `agent_definition_read`,
`agent_trigger_set` and `agent_trigger_remove`, and the policy names them so:

```yaml title="~/.config/wardrik/policies/growth.yaml"
allow:
  # ...the rules above, and:
  - agent_definition_read
ask:
  # ...the rules above, and:
  agent_trigger_set: This changes what it watches.
  agent_trigger_remove: This stops one of its triggers.
```

An agent its file declares keeps the triggers its file lists, so an agent that changes its own is
defined over the HTTP API. Take `growth.md` out of `agents/` and run `wardrik reload`, since a key a
file declares is the file's; the agent stops, keeping its conversation. Save the file's body, below
its frontmatter, as `instructions.md`, and define the agent again with a token that can `define`
and holds what it defines to the policy:

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

Add a line to its instructions for it, such as "When you find a feed worth watching, set a trigger
for it; when one has told you nothing worth acting on for a month, remove it." Now it proposes
what it watches as it proposes the rest, and the team can ask for a change in `#growth`:

> **maria:** @Wardrik Billwise has a changelog feed now, billwise.example/changelog.rss. Watch it.
> ↳ **Wardrik:** Waiting on @maria or @sam to approve `agent_trigger_set`.

Approved, the trigger is set, `wardrik triggers` lists it, and `wardrik audit` records the agent as
who set it. A definition sent over HTTP has no `notify`, so its triggered runs post nothing to
`#growth`: find what they wait on with `wardrik parked`, in the [terminal client](/build/tui/),
or over the HTTP API. A conversation in a Slack thread asks the approvers as before.

## A record of what it did

Every message, tool call, decision and refusal is an event on the agent's stream:
`tool_call.started` says who let a call run, a person or the policy, `interrupt.resolved` who
approved or denied it and what they wrote, `tool_call.denied` why a rule refused it, and
`tool_call.completed` what it cost. `wardrik watch growth --json` follows them, a line each. See
[The event stream](/concepts/events/).

`wardrik audit` lists what was changed, by whom: an agent defined, a trigger set, a token made.
`wardrik show growth` says what the agent has spent in its period.

## Trusting it with more

How much it does alone is the policy's to say, and the policy is a file you review like code. Start
with every outside effect asking, read what the team approves, and loosen where they approve the
same call every time. Here are the rules that change, with the rest of the policy as it was, so
that the agent may launch a campaign at up to $50 a day, while bigger ones still ask and the
biggest are refused:

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

The `ask` rule now names only the calls over $50, since an ask decides over an `allow_after` that
names the same call. A call that gives no `daily_budget`, such as one that only launches or pauses,
matches neither rule, and waits on a person as a gated call does. `wardrik reload` gives the running
agent the new rules, and a call already waiting that they allow runs without a person. See
[Changing the policy while it waits](/concepts/policy/#changing-the-policy-while-it-waits).

Some things to keep in mind as it gets more rope:

- **Allow after outside only what a stranger cannot turn against you.** Its feeds are written by
  people you do not know, so any call it may make alone is one they could ask for. A paused draft,
  or a capped budget change, does bounded harm; publishing a post in your name does not.
- **The budget counts what the agent spends, not what its calls set going.** A campaign it
  launches spends on the ad platform, outside the budget, so cap that with argument rules, as here,
  and with the platform's own limits.
- **Let rules decide exact matters.** A tool's name and its arguments are a rule's to decide; for
  what a call means, such as whether a post makes a claim about a competitor, a
  [judge](/concepts/policy/#judged-calls) can ask a person about it.

## What it shows

- **Next steps as calls.** The agent proposes by calling its tools, so approving a proposal is doing
  it, and denying one teaches it why.
- **Work that runs and work that waits.** Research and drafts run on their own; whatever leaves the
  deployment waits on a named approver in Slack. See [Policy and approvals](/concepts/policy/).
- **Rules that know what the agent read.** Once it has read a stranger's words, only tools the
  policy allows after outside content run without a person. See
  [Content from outside](/concepts/policy/#content-from-outside).
- **A budget over everything it spends.** Model calls, priced tools and what a tool reports it cost
  come out of one daily meter.
- **Memory of what was decided.** Approvals and denials go into a file read into every turn, so its
  next proposals follow the team's.
- **A record.** Every call, who decided it and what it cost, on one stream of events.

## Taking it further

- Let it open pull requests: give the GitHub server the tools to make a branch, push to it and open
  a pull request, and allow pushing to its own branches with an argument rule under `allow_after`,
  in the arguments those tools take, so only the pull request waits on a person. Do so only where
  pushing a branch runs nothing with your secrets.
- Have it watch where people talk about you, as well as your competitors, with a feed of a Google
  Alert or a Reddit search, and propose replies where your tools can post them.
