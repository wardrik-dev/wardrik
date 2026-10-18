# Agent files

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

`wardrik reload` reads the agent files again and starts what changed. A file that doesn't read says
why, and an agent already running keeps what it had. A file with no frontmatter is all prompt.

## Keys

| Key | Means |
| --- | --- |
| `name` | its name; the file's name without `.md` unless set |
| `org` | the org it belongs to, one `config.yaml` declares; its `org` unless set |
| `user` | the user of its org it works for, if any |
| `description` | what it is for, as `wardrik show` shows it |
| `model` | the model, as `provider:model` |
| [`tools`](#tools) | what it may call |
| [`workspace`](#workspace) | the trees of files it shares with other agents |
| [`context`](#workspace) | the files read into each turn |
| [`policy`](#policy) | what its tool calls may do |
| `timeout` | seconds a turn may take |
| `idle_timeout` | seconds it may have nothing to do before it sleeps, or `infinity`; 900 unless `config.yaml`'s `defaults` say otherwise. A sleeping agent wakes when something asks it |
| `max_iterations` | rounds of tool calls a turn may make, or `infinity` |
| [`retries`](#retries) | how long to wait before asking a failed model call again |
| `compaction` | when it summarises its older history, as `at`, `keep` and `window`, or `false` never to |
| [`triggers`](#triggers) | when it is asked something on a clock, by a feed, or by a webhook |
| [`notify`](#notify) | who hears when it waits on a person, fails or answers |
| [`channels`](#channels) | the chat channels it may answer in |

Keys an agent file leaves out come from `config.yaml`'s [`defaults`](config.md#defaults).

Its ID is `org/name`, or `org/@user/name` for one that works for a user: the file above, with
`org: acme` and `user: jon`, would be `acme/@jon/triage`. The CLI finds an agent of the deployment's
org by its name alone.

## tools

What the agent may call. An agent whose file lists none has none.

| Entry | Gives it |
| --- | --- |
| `web_search`, `deep_research`, `run_lua` | a tool the daemon ships, by name |
| `files` | the file tools, over its own tree and the trees it shares |
| `server/*` | every tool of an MCP server its owner added, else one `config.yaml` names; a server's `only` and `except` narrow them |
| `workers/*` | every tool the connected [tool workers](https://docs.wardrik.dev/build/tool-workers/) offer it |
| `self/*` | its operations on itself: reading its snapshot and definition, and changing its own triggers |
| `agents/*` | its operations on the other agents of its org; see [Delegating](#delegating) |
| `servers/*` | every tool of the MCP servers its owner has added as the daemon runs |
| `*` | all of the above |

An agent reaches an MCP server that serves its org; a file naming one it can't reach doesn't read.
A server its owner hasn't added yet offers nothing until they add it, and the definition lists it
as missing when it is read.
A [policy](#policy) narrows what it may call.

### Delegating

`agents/*` lets the agent work with the other agents of its org, each named as `reconciler`, or
`@jon/reconciler` for one that works for a user:

| Tool | Does |
| --- | --- |
| `agents_list` | lists the agents of the org, and what each is doing |
| `agent_read` | reads one's snapshot: its status, what it waits on, its conversation |
| `agent_definition_read` | reads one's definition |
| `agent_ask` | sends one a message, whose answer comes back later |
| `agent_define` | defines a worker, or defines one again |
| `agent_trigger_set`, `agent_trigger_remove` | changes one's triggers |

Asking and defining wait on a person, as every change does, unless the policy allows them:

```yaml
tools: [agents/*]
policy:
  allow: [agent_ask]
```

An agent defined this way is held to the policies and budget of the agent that defined it, so a
worker is never looser than the agent that made it. See
[Delegate to other agents](https://docs.wardrik.dev/build/delegation/).

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

A tree is reachable by the agents under the org or user its name begins with, and by those
`config.yaml`'s [`workspace.shared`](config.md#workspace) lets mount it, in the mode it lets them. A
file naming one its agent can't reach doesn't read.

`context` names files read into every turn, up to 16 KB of them in all. The agent is also told the
names of the other files at the top of its tree, which it reads when it needs them:

```yaml
tools: [files]
context: [MEMORY.md, shared/team/CONVENTIONS.md]
```

`max_bytes` reads more or less into each turn, from 1,024 to 262,144 bytes:

```yaml
context:
  files: [SOUL.md, MEMORY.md]
  max_bytes: 65536
```

A file longer than its share is read from its start and its end, and the agent is asked to make it
shorter. See [Files and memory](https://docs.wardrik.dev/concepts/files-and-memory/).

## policy

The name of a policy in `policies/`, as `policy: careful` for `policies/careful.yaml`, or rules
written in place:

```yaml
policy:
  ask: [github/*]
  deny: [shell/*]
```

Without one, every call the agent's tools allow may run, apart from a gated tool's, which waits on a
person. See [Policies](`e:wardrik:policies.html`) for what a policy holds.

## retries

The waits, in seconds, before a model call that failed for a passing reason, such as a timeout, a
dropped connection or a provider's 5xx, is asked again. The turn fails after the last.

```yaml
retries: [2, 10, 30]    # after 2s, then 10s, then 30s
retries: []             # never ask again
```

`[1, 5]` unless `config.yaml`'s `defaults` say otherwise.

## triggers

One trigger or a list of them, each asking the agent something on a clock, when a feed has something
new, or when a service sends it a webhook:

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
| `every` | a cron expression, quoted, or a duration of at least a minute, as `30m`, `2h` or `1d`; a webhook trigger has none |
| `timezone` | the time zone a cron expression is read in, by its IANA name, as `Europe/Berlin`; `Etc/UTC` unless set. A duration takes none |
| `prompt` | what the agent is asked |
| `prompt_file` | in place of `prompt`, a file in its workspace it is asked to read and follow, so it can edit its own checklist; needs `files` |
| `name` | the trigger's name; `trigger-1`, `trigger-2` and so on by its place unless set |
| `overlap` | `skip` leaves a busy agent be, `queue` asks it anyway; `skip` unless set, `queue` for a webhook |
| `missed` | `run_once` runs once for what was missed while the daemon was down, `skip` lets it go; `run_once` unless set |
| `jitter` | up to this many seconds added to each run |
| `feed` | an RSS or Atom feed's URL, or a list of them; the agent is asked only when one has new entries, with them under the prompt. The first run only notes what a feed holds |
| `webhook` | a service sends it requests in place of a clock; see below |

A webhook trigger takes `secret`, the secret the service holds, as `${NAME}`, and `verify`:
`shared`, where a request presents the secret as a bearer token or at the end of its path, or
`standard`, where it is signed as the Standard Webhooks spec says. `shared` unless set. The service
sends requests to `config.yaml`'s `base_url` and `/v1/hooks/{agent}/{trigger}`, which `wardrik
triggers` prints, and the agent is asked about each once, with its body under the prompt. See
[Trigger an agent](https://docs.wardrik.dev/build/triggers/).

## notify

Routes the agent's notices to targets `config.yaml`'s [`notify`](config.md#notify) names:

```yaml
notify: ops                      # waiting and failed turns, to ops
notify: [ops, audit]
notify: {to: [ops], on: [parked, failed, finished]}
```

`on` lists what is sent: `parked` for a call waiting on a person, `failed`, and `finished` for what
a turn answered. A target serves one org's agents; a file routing to another org's doesn't read.

## channels

The channels of `config.yaml`'s [`channels`](config.md#channels) the agent may be offered in.
Inviting a channel's bot into a room then offers it there:

```yaml
channels: [slack]
```

## Written by wardrik

`wardrik agent spawn` writes a file here from `config.yaml`'s `defaults` and a short prompt to edit.
`wardrik init` writes the front door's, whose body is its instructions and a playbook to edit; see
[The front door](https://docs.wardrik.dev/build/front-door/).

## Over HTTP

A definition sent with `PUT /v1/agents/{id}` takes the same keys, as JSON, with `instructions` in
place of the body; the ID gives its name, org and user. Its `policy` may write rules in place, but
not `allow_after`: name a policy in `policies/` that has it. Its `workspace` shares only the trees
its token reaches. See the
[HTTP API](`e:wardrik_http:http-api.html#agents`).
