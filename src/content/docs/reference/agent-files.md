---
title: "Agent files"
description: "An agent is a Markdown file in agents/ under the config directory. Its frontmatter says what it is and what it may do, and its body is its system prompt."
sidebar:
  order: 3
---

An agent is a Markdown file in `agents/` under the config directory. Its frontmatter says what it is
and what it may do, and its body is its system prompt. This is `~/.config/wardrik/agents/triage.md`:

```markdown
---
description: Watches the incident queue and says what needs an engineer.
model: anthropic:claude-sonnet-5
tools: [web_search, linear/*]
policy: careful
---
You watch the incident queue. Summarise anything new, and say which
issues need an engineer.
```

- A file with no frontmatter is all prompt.
- The daemon reads `agents/` as it starts. `wardrik reload` reads it again, on every node.
- An agent awake takes what its file says from its next turn. One asleep takes it as it wakes.
- A file that doesn't read is logged with why, and its agent keeps what it had. `wardrik doctor`
  checks every file without starting anything.
- An agent whose file is gone is removed on the next reload.

## Keys

| Key | Means |
| --- | --- |
| `name` | its name; the file's name without `.md` unless set |
| `org` | the org it belongs to: the deployment's [`org`](/reference/config/#org); a file naming another doesn't read |
| `user` | the user of its org it works for, if any |
| `display_name` | what a person calls it; its name unless set |
| `description` | what it is for, as `wardrik agent show` shows it |
| `model` | required. The model, as `provider:model` |
| [`tools`](#tools) | what it may call |
| [`workspace`](#workspace) | the trees of files it shares with other agents |
| [`context`](#context) | the files read into each turn |
| [`policy`](#policy) | what its tool calls may do |
| `timeout` | seconds a turn may take; no limit unless set |
| `idle_timeout` | seconds it may have nothing to do before it sleeps, or `infinity`; `900` unless set. A sleeping agent wakes when something asks it |
| `max_iterations` | rounds of tool calls a turn may make; `25` unless set. `infinity` isn't supported yet |
| [`retries`](#retries) | how often a failed model call is tried again, and what happens after |
| [`compaction`](#compaction) | when it summarises its older history, or `false` never to |
| [`triggers`](#triggers) | when it is asked something on a clock, by a feed, or by a webhook |
| [`notify`](#notify) | who hears when it waits on a person, fails or answers |
| [`channels`](#channels) | the chat channels it may answer in |

Keys a file leaves out come from `config.yaml`'s [`defaults`](/reference/config/#defaults). A
policy it names is one in `policies/`, which the daemon reads as it starts.

Its ID is `org/name`, or `org/@user/name` for one that works for a user. The file above, with
`org: acme` and `user: jon`, is `acme/@jon/triage`. The CLI finds an agent of the deployment's org
by its name alone.

## tools

What the agent may call. An agent whose file lists none has none.

| Entry | Gives it |
| --- | --- |
| `web_search` | searches the web through Brave; needs [`brave`](/reference/config/#brave) |
| `deep_research` | splits a topic into angles, and has a subagent with the agent's own tools research each at once |
| `run_lua` | runs Lua in a sealed sandbox, for arithmetic, reshaping data and the current time |
| `files` | the file tools, over its own tree and the trees it shares: `read_file`, `write_file`, `edit_file`, `list_files`, `search_files` and `delete_file` |
| `server/*` | every tool of an MCP server: one its owner added, else one `config.yaml`'s [`mcp`](/reference/config/#mcp) names. A server's `only` and `except` narrow them |
| `servers/*` | every tool of every MCP server its owner has added |
| `workers/*` | every tool the connected [tool workers](/build/tool-workers/) offer it |
| `self/*` | its operations on itself; see [Itself](#itself) |
| `agents/*` | its operations on the other agents of its org; see [Delegating](#delegating) |
| `*` | all of the above |

- An agent reaches an MCP server that serves its org.
- A name that is neither a tool nor `NAME/*` doesn't read.
- A server its owner hasn't added yet offers nothing until they add it. Its definition lists it as
  `missing` meanwhile.
- A [policy](#policy) narrows what it may call.

### Itself

`self/*` gives the agent these tools:

| Tool | Does |
| --- | --- |
| `self_read` | reads its own snapshot: its status, and what it waits on |
| `self_definition_read` | reads its own definition |
| `self_trigger_set`, `self_trigger_remove` | changes its own triggers |

### Delegating

`agents/*` lets the agent work with the other agents of its org, each named as `reconciler`, or
`@jon/reconciler` for one that works for a user:

| Tool | Does |
| --- | --- |
| `agents_list` | lists the agents of the org, and what each is doing |
| `agent_read` | reads one's snapshot: its status, and what it waits on |
| `agent_definition_read` | reads one's definition |
| `agent_ask` | sends one a message, whose answer comes back later as a message |
| `agent_define` | defines a worker, or defines one again |
| `agent_trigger_set`, `agent_trigger_remove` | changes one's triggers |

Reads always run. Changes, here and in `self/*`, are gated: they wait on a person unless the policy
allows them by name.

```yaml
tools: [agents/*]
policy:
  allow: [agent_ask]
```

An agent defined this way is held to the policy of the agent that defined it, so a worker is never
looser than the agent that made it. A message `agent_ask` sends carries the labels of what the
asking run has read. See [Delegate to other agents](/build/delegation/).

## workspace

`files` gives the agent a tree of its own, kept in the store, and `workspace` shares others with it,
each seen under `shared/<name>/`:

```yaml
tools: [files]
workspace:
  shared:
    team: acme                                  # acme's tree, read and written
    runbooks: {tree: acme/runbooks, mode: read}
```

- A tree is named `org`, `org/name` or `org/@user/name`.
- A shared entry is a tree, or `tree` and `mode`: `read` or `write`. `write` unless set.
- The agents of the org or user a tree's name begins with may mount it.
- Other agents may mount it where `config.yaml`'s
  [`workspace.shared`](/reference/config/#workspace) lets them, in the mode it lets them.
- A file naming a tree its agent can't reach doesn't read.
- An agent's conversations share its tree.

## context

`context` names files read into every turn, at most 20, from its tree or one it shares. The agent
is also told the names of the other files at the top of its tree, which it reads when it needs them.

```yaml
tools: [files]
context: [MEMORY.md, shared/team/CONVENTIONS.md]
```

They're read up to 16 KB in all. `max_bytes` reads more or less, from 1,024 to 262,144 bytes:

```yaml
context:
  files: [SOUL.md, MEMORY.md]
  max_bytes: 65536
```

A file longer than its share is read from its start and its end, and the agent is asked to make it
shorter. See [Files and memory](/concepts/files-and-memory/).

## policy

The name of a policy in `policies/`, as `policy: careful` for `policies/careful.yaml`, or rules
written in place:

```yaml
policy:
  ask: [github/*]
  deny: [shell/*]
```

Without one, every call the agent's tools allow may run, apart from a gated tool's, which waits on a
person. See [Policies](/reference/policies/) for what a policy holds.

## retries

How a turn tries a failed model call again.

```yaml
retries:
  attempts: 6          # tries after the first; 0 never tries again
  max_wait: 60         # seconds, the longest wait between tries
  on_exhausted: ask    # once spent: ask a person to try again, or fail
```

| Key | Means |
| --- | --- |
| `attempts` | tries after the first; `6` unless set; `0` never tries again |
| `max_wait` | the longest wait between tries, in seconds; `60` unless set |
| `on_exhausted` | once the tries are spent: `ask` a person whether to try again, or `fail` the turn; `ask` unless set |

- Before each try it waits a random while: up to a second, then up to two, then four, and so on,
  never more than `max_wait`.
- Where the provider says how long to wait, in a `Retry-After` header, it waits that long instead.
- A timeout, a dropped connection, a broken stream, a rate limit and a provider's 5xx are tried
  again.
- A 4xx other than 408, 425 and 429 goes straight to `on_exhausted`.

With `ask`, the turn waits on a person, as for an approval. Approving tries again with a fresh set
of tries. Denying fails the turn.

## compaction

When the agent summarises its older history, as shares of the model's context window. `false` never
does.

```yaml
compaction:
  at: 0.6      # summarise once the history fills this share of the window
  keep: 0.25   # the share of the window kept word for word
```

| Key | Means |
| --- | --- |
| `at` | the share of the window that starts a summary, between 0 and 1; `0.6` unless set |
| `keep` | the share of the window kept word for word, between 0 and 1; `0.25` unless set |
| `window` | the model's window in tokens, where the catalog doesn't know it; `128000` unless set |

The agent's own model writes the summary, so its policy and budget apply. The summary keeps the
labels of what it replaces, such as `outside`.

## triggers

A list of triggers, each asking the agent something on a clock, when a feed has something new, or
when a service sends it a webhook:

```yaml
triggers:
  - name: sweep
    every: "*/30 * * * *"
    prompt: Check the incident queue.
  - name: rivals
    every: 1h
    feed: [https://rivalco.example/changelog.rss]
    prompt: What changed at our competitors?
  - name: issues
    webhook:
      secret: ${ISSUES_HOOK_SECRET}
    prompt: An event is below. Triage it.
```

| Key | Means |
| --- | --- |
| `every` | a cron expression, quoted, as `"0 9 * * 1-5"` or `@daily`; or an interval of at least a minute, as `90s`, `30m`, `2h` or `1d`. A webhook trigger has none |
| `timezone` | the time zone a cron expression is read in, by its IANA name, as `Europe/Berlin`; `Etc/UTC` unless set. An interval takes none |
| `prompt` | what the agent is asked |
| `prompt_file` | in place of `prompt`, a file in its tree it is asked to read and follow, so it can edit its own checklist; needs `files` |
| `name` | the trigger's name, holding no `/`, `:` or whitespace; `trigger-1`, `trigger-2` and so on by its place unless set |
| `overlap` | `skip` leaves a busy agent be, `queue` asks it anyway; `skip` unless set, `queue` for a webhook |
| `missed` | `run_once` runs once for what was missed while the daemon was down, `skip` lets it go; `run_once` unless set |
| `jitter` | up to this many seconds added to each run; `0` unless set |
| `feed` | an RSS or Atom feed's URL, or a list of them. The agent is asked only when one has new entries, with them under the prompt. The first run only notes what a feed holds |
| `webhook` | a service sends it requests in place of a clock; see below |

A trigger has a `prompt` or a `prompt_file`, not both.

A webhook trigger takes:

| Key | Means |
| --- | --- |
| `secret` | required. The secret the service holds, as `${NAME}` |
| `verify` | `shared`, where a request presents the secret as a bearer token or at the end of its path; or `standard`, where it is signed as the Standard Webhooks spec says; `shared` unless set |

The service sends requests to `config.yaml`'s `base_url` and `/v1/hooks/{agent}/{trigger}`. The
agent is asked about each request once, with its body under the prompt. See
[Trigger an agent](/build/triggers/).

## notify

Routes the agent's notices to targets `config.yaml`'s [`notify`](/reference/config/#notify) names, or
to a room of one of its [`channels`](/reference/config/#channels), as `channel:room`:

```yaml
notify: ops                      # waiting and failed turns, to ops
notify: [ops, "slack:#updates"]
notify: {to: [ops], on: [parked, failed, finished]}
```

- `on` lists what is sent: `parked` for a call waiting on a person, `failed`, and `finished` for
  what a turn answered. `parked` and `failed` unless set.
- A target that isn't there, or doesn't tell the agent's org, stops the file reading.
- A room is posted in a workspace of the agent's own owner.

## channels

The channels of `config.yaml`'s [`channels`](/reference/config/#channels) the agent may be offered in.
Inviting a channel's bot into a room then offers it there, where the channel serves its org. A
channel `config.yaml` doesn't name stops the file reading.

```yaml
channels: [slack]
```

## Written by wardrik

`wardrik init` writes the front door, `agents/assistant.md`, whose body is its instructions and a
playbook to edit. See [The front door](/build/front-door/).

## Over HTTP

A definition sent with `PUT /v1/agents/{agent}` takes the same keys, as JSON, with `instructions` in
place of the body. The ID gives its name, org and user.

- Its `policy` may write rules in place, but not `allow_after`: name a policy in `policies/` that
  has it.
- Its `workspace` shares only the trees its token reaches.
- An agent a file declares takes its file's definition again on the next reload, and can't be
  removed over HTTP.

See the [HTTP API](/reference/http-api/#agents).
