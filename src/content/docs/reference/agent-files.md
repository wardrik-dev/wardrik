---
title: "Agent files"
description: "The keys of an agent file in agents/, and of a definition sent over the HTTP API."
sidebar:
  order: 3
---

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

- An agent file is `agents/NAME.md` in the [config directory](/reference/config/#directories). The file name is the agent's name.
- The frontmatter is the definition. The body is its `instructions`, the system prompt.
- `wardrik reload` reads `agents/` again. An agent takes its new definition from its next turn.
- A file that doesn't read keeps its last definition, and the log says why. `wardrik doctor` checks every file.
- Removing a file forgets its agent on the next reload.
- Keys a file leaves out come from `config.yaml`'s [`defaults`](/reference/config/#defaults).

## Keys

| Key | Description |
| --- | --- |
| `org` | the deployment's `org` or one in `orgs`; the owner's org unless set (files only) |
| `owner` | its org, or a person in it, as `"@jon"` or `acme/@jon`; its org unless set (files only) |
| `display_name` | what a person calls it; its name unless set |
| `description` | what it's for |
| `instructions` | the system prompt; the file's body |
| `model` | the model, as `provider:model` |
| [`tools`](#tools) | what it may call |
| [`workspace`](#workspace) | other agents' workspaces it mounts |
| [`context`](#context) | files read into every turn |
| [`policy`](#policy) | a policy's name, or rules in place |
| `timeout` | seconds a turn may take; no limit unless set |
| `idle_timeout` | seconds idle before it sleeps, or `infinity`; `900` unless set |
| `max_iterations` | rounds of tool calls a turn may make, or `infinity`; `25` unless set |
| [`retries`](#retries) | how a failed model call is tried again |
| [`compaction`](#compaction) | when older history is summarised, or `false` |
| [`triggers`](#triggers) | when it's asked something on its own |
| [`notify`](#notify) | who hears when it waits, fails or answers |
| `channels` | the [`channels`](/reference/config/#channels) it may answer in, as `[slack]` |

Over HTTP, [`PUT /v1/agents/{agent}`](/reference/http-api/#define-an-agent) takes the same keys as JSON,
except `org` and `owner`.

## tools

```yaml
tools: [web_search, files, github/*, agents/*]
```

| Entry | Gives |
| --- | --- |
| `web_search` | web search through Brave; needs [`brave.api_key`](/reference/config/#keys) |
| `deep_research` | researches a topic with subagents |
| `run_lua` | Lua in a sealed sandbox |
| `agent_create` | makes a worker agent in its org |
| `files` | `read_file`, `write_file`, `edit_file`, `list_files`, `search_files`, `delete_file` over its workspace and the ones it mounts |
| `NAME/*` | every tool of the MCP server `NAME` |
| `servers/*` | every tool of every MCP server its owner added |
| `workers/*` | every tool connected [tool workers](/build/tool-workers/) offer it |
| `self/*` | `self_read`, `self_definition_read`, `self_trigger_set`, `self_trigger_remove` |
| `agents/*` | `agents_list`, `agent_read`, `agent_definition_read`, `agent_ask`, `agent_define`, `agent_trigger_set`, `agent_trigger_remove` |
| `*` | all of the above |

- A server not added yet offers nothing. [`GET .../definition`](/reference/http-api/#read-a-definition) lists it as `missing`.
- In `self/*` and `agents/*`, reads always run. Changes wait on a person unless the policy allows them by name.
- A worker an agent defines is held to its definer's policy.

## workspace

```yaml
tools: [files]
workspace:
  shared:
    team: agent:runbooks                   # the runbooks agent's workspace, at shared/team/
    notes: {agent: agent:notes, mode: read}
```

- Each entry is an agent in the same org, as `agent:NAME`, or `agent` and `mode` (`read` or `write`).
- It's mounted at `shared/<name>/`.
- It mounts only what `config.yaml`'s [`workspace.shared`](/reference/config/#workspace) allows.
  `mode: read` mounts a writable share read-only.
- Over HTTP, entries are agent IDs.

## context

```yaml
context: [MEMORY.md, shared/team/CONVENTIONS.md]
```

```yaml
context:
  files: [SOUL.md, MEMORY.md]
  max_bytes: 65536
```

- Up to 20 files, from its workspace or one it mounts. Needs `files` in `tools`.
- Up to 16 KB in all, or `max_bytes` (1,024 to 262,144).

## policy

```yaml
policy: careful                  # policies/careful.yaml
```

```yaml
policy:
  ask: [github/*]
  deny: [shell/*]
```

See [Policies](/reference/policies/).

## retries

```yaml
retries: {attempts: 6, max_wait: 60, on_exhausted: ask}
```

| Key | Default | Description |
| --- | --- | --- |
| `attempts` | `6` | tries after the first; `0` never tries again |
| `max_wait` | `60` | longest wait between tries, in seconds |
| `on_exhausted` | `ask` | `ask` a person whether to try again, or `fail` the turn |

- The wait is random, up to a second, doubling each time.
- A 4xx answer other than 408, 425 and 429 isn't tried again.

## compaction

```yaml
compaction: {at: 0.6, keep: 0.25}
```

| Key | Default | Description |
| --- | --- | --- |
| `at` | `0.6` | share of the model's window that starts a summary |
| `keep` | `0.25` | share of the window kept word for word |
| `window` | the catalog's, or `128000` | the model's window in tokens |

## triggers

```yaml
triggers:
  - name: sweep
    every: "*/30 * * * *"
    prompt: Check the incident queue.
  - name: rivals
    every: 1h
    feed: https://rivalco.example/changelog.rss
    prompt: What changed at our competitors?
  - name: issues
    webhook: {secret: "${ISSUES_HOOK_SECRET}"}
    prompt: An event is below. Triage it.
```

| Key | Default | Description |
| --- | --- | --- |
| `name` | `trigger-1`, `trigger-2`... | the trigger's name |
| `every` | | a cron expression, or an interval like `30m` |
| `timezone` | `Etc/UTC` | the IANA zone a cron expression is read in |
| `prompt` | | what the agent is asked |
| `prompt_file` | | in place of `prompt`, a file in its workspace it reads and follows |
| `overlap` | `skip` | `skip` or `queue` a firing while a run is going |
| `missed` | `run_once` | `run_once` or `skip` what was missed while down |
| `jitter` | `0` | up to this many seconds of random delay |
| `feed` | | RSS or Atom URLs; asks only when one has new entries |
| `webhook` | | in place of `every`: `secret`, and `verify` (`shared` or `standard`) |

A webhook trigger takes requests at [`POST /v1/hooks/{agent}/{trigger}`](/reference/http-api/#deliver-a-webhook).

## notify

```yaml
notify: ops
notify: [ops, "slack:#updates"]
notify: {to: [ops], on: [parked, failed, finished]}
```

- A target is one from `config.yaml`'s [`notify`](/reference/config/#notify), one added for the owner, or a room as `channel:room`.
- `on` is `parked` and `failed` unless set.
