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
- The frontmatter is the definition. The body is the `instructions`, the system prompt.
- `wardrik reload` rereads `agents/`. A new definition applies from the agent's next turn.
- If a file fails to parse, the agent keeps its last definition and the error is logged. `wardrik doctor` checks every file.
- Deleting a file removes its agent on the next reload.
- Omitted keys default to `config.yaml`'s [`defaults`](/reference/config/#defaults).

## Keys

| Key | Description |
| --- | --- |
| `org` | the deployment's `org` or one in `orgs`; default: the owner's org (files only) |
| `owner` | the org, or a user in it, as `"@jon"` or `acme/@jon`; default: the org (files only) |
| `display_name` | display name; default: the name |
| `description` | a short description |
| `instructions` | the system prompt; the file's body |
| `model` | the model, as `provider:model` |
| [`tools`](#tools) | the tools it can call |
| [`workspace`](#workspace) | other agents' workspaces to mount |
| [`context`](#context) | files loaded into every turn |
| [`policy`](#policy) | a policy name, or inline rules |
| `timeout` | a turn's limit in seconds, then `run.deadline_exceeded`; default: none |
| `idle_timeout` | idle seconds before the process stops, or `infinity`; default `900` |
| `max_iterations` | rounds of tool calls per turn, or `infinity`, then the turn fails; default `25` |
| [`retries`](#retries) | retry settings for failed model calls |
| [`compaction`](#compaction) | when older history is summarised, or `false` |
| [`triggers`](#triggers) | scheduled, feed and webhook messages |
| [`notify`](#notify) | notice targets for paused, failed or finished turns |
| `channels` | the [`channels`](/reference/config/#channels) it's available in, as `[slack]` |

Over HTTP, [`PUT /v1/agents/{agent}`](/reference/http-api/#define-an-agent) takes the same keys as JSON,
except `org` and `owner`.

## tools

```yaml
tools: [web_search, files, github/*, agents/*]
```

| Entry | Tools |
| --- | --- |
| `web_search` | web search through Brave; requires [`brave.api_key`](/reference/config/#keys) |
| `deep_research` | researches a topic with subagents |
| `run_lua` | runs Lua in a sandbox |
| `agent_create` | creates a worker agent in its org |
| `files` | `read_file`, `write_file`, `edit_file`, `list_files`, `search_files`, `delete_file` on its workspace and mounts |
| `NAME/*` | every tool of the MCP server `NAME` |
| `servers/*` | every tool of every MCP server its owner added |
| `workers/*` | every tool that connected [tool workers](/build/tool-workers/) serve to it |
| `self/*` | `self_read`, `self_definition_read`, `self_trigger_set`, `self_trigger_remove` |
| `agents/*` | `agents_list`, `agent_read`, `agent_definition_read`, `agent_ask`, `agent_define`, `agent_trigger_set`, `agent_trigger_remove` |
| `*` | all of the above |

- A server that isn't added yet has no tools. [`GET .../definition`](/reference/http-api/#read-a-definition) lists it as `missing`.
- In `self/*` and `agents/*`, reads always run. Changes need approval unless the policy allows them by name.
- A worker inherits the policy of the agent that defined it.

## workspace

```yaml
tools: [files]
workspace:
  shared:
    team: agent:runbooks                   # the runbooks agent's workspace, at shared/team/
    notes: {agent: agent:notes, mode: read}
```

- Each entry is an agent in the same org, as `agent:NAME`, or a map of `agent` and `mode` (`read` or `write`).
- Each is mounted at `shared/<name>/`.
- Only mounts allowed by `config.yaml`'s [`workspace.shared`](/reference/config/#workspace) succeed.
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

- Up to 20 files, from its workspace or a mount. Requires `files` in `tools`.
- Up to 16 KB total, or `max_bytes` (1,024 to 262,144).

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
| `attempts` | `6` | retries after the first attempt; `0` disables retries |
| `max_wait` | `60` | maximum backoff between retries, in seconds |
| `on_exhausted` | `ask` | `ask` for approval to retry, or `fail` the turn |

- Backoff is exponential with jitter, starting under one second.
- A 4xx response other than 408, 425 and 429 isn't retried.

## compaction

```yaml
compaction: {at: 0.6, keep: 0.25}
```

| Key | Default | Description |
| --- | --- | --- |
| `at` | `0.6` | fraction of the context window that triggers a summary |
| `keep` | `0.25` | fraction of the window kept verbatim |
| `window` | the catalog's, or `128000` | the context window in tokens |

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
| `timezone` | `Etc/UTC` | the IANA time zone for the cron expression |
| `prompt` | | the message sent to the agent |
| `prompt_file` | | instead of `prompt`, a workspace file to read the message from |
| `overlap` | `skip` | `skip` or `queue` a run while the agent is busy |
| `missed` | `run_once` | `run_once` or `skip` runs missed while the daemon was down |
| `jitter` | `0` | maximum random delay in seconds |
| `feed` | | RSS or Atom URLs; sends only when a feed has new entries |
| `webhook` | | instead of `every`: `secret`, and `verify` (`shared` or `standard`) |

A webhook trigger receives requests at [`POST /v1/hooks/{agent}/{trigger}`](/reference/http-api/#deliver-a-webhook).

## notify

```yaml
notify: ops
notify: [ops, "slack:#updates"]
notify: {to: [ops], on: [parked, failed, finished]}
```

- A target is a name from `config.yaml`'s [`notify`](/reference/config/#notify), a webhook added for the owner, or a room as `channel:room`.
- `on` defaults to `[parked, failed]`.
