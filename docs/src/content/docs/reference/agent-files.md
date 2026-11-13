---
title: "Agent files"
description: "Configuration fields for Markdown agent files and JSON agent definitions."
sidebar:
  order: 3
---

Define an agent with YAML configuration and Markdown instructions. The same settings are
available as JSON through the HTTP API.

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
- The YAML frontmatter configures the agent. The Markdown body becomes its `instructions` (system prompt).
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
| `instructions` | the system prompt; the Markdown body |
| `model` | the model, as `provider:model` |
| [`tools`](#tools) | the tools it can call |
| [`workspace`](#workspace) | other agents' workspaces to mount |
| [`context`](#context) | files loaded into every turn |
| [`policy`](#policy) | a policy name, or inline rules |
| `timeout` | a turn's limit in seconds, then `run.deadline_exceeded`; default: none |
| `idle_timeout` | idle seconds before the process stops, or `infinity`; default `900` |
| `max_iterations` | rounds of tool calls per turn, or `infinity`, then the turn fails; default `25` |
| [`retries`](#retries) | retry settings for failed model calls |
| [`model_options`](#model_options) | sampling and timeouts for its model calls |
| [`compaction`](#compaction) | when older history is summarised, or `false` |
| [`digest`](#digest) | whether it writes a digest of each conversation before it sleeps; default `true` |
| [`triggers`](#triggers) | scheduled, one-off, feed and webhook messages |
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
| `web_search` | web search through Brave; needs a key, sealed with `wardrik vault put BRAVE_API_KEY --for api_key` or set as [`brave.api_key`](/reference/config/#keys). A key in the environment counts only through `brave.api_key`. Until it has one, it says how to add one |
| `deep_research` | researches a topic with subagents |
| `run_lua` | runs Lua in a sandbox |
| `agent_create` | creates another agent in the same organization |
| `files` | `read_file`, `write_file`, `edit_file`, `list_files`, `search_files`, `delete_file` on its workspace and mounts |
| `NAME/*` | every tool of the MCP server `NAME` |
| `servers/*` | every tool of every MCP server its owner added |
| `workers/*` | every tool that connected [tool workers](/build/tool-workers/) serve to it |
| `self/*` | `self_read`, `self_definition_read`, `self_schedule`, `self_trigger_set`, `self_trigger_remove` |
| `agents/*` | `agents_list`, `agent_read`, `agent_definition_read`, `agent_ask`, `agent_define`, `agent_schedule`, `agent_trigger_set`, `agent_trigger_remove` |
| `ops/read` | every operation that only reads, as a tool named after it: `agent_runs`, `agent_timeline`, `agent_calls`, `agent_resolved`, `agent_runtime`, `interrupts_list`, `audit_list`, `deployment_nodes`, `deployment_runtime` and the rest |
| `ops/ID` | one operation, such as `ops/agent.runs` or `ops/agent.stop`. Approving and denying calls are never tools |
| `settings` | `settings_list`, `server_add`, `notify_target_add`, `oauth_app_add`, `secret_request` |
| `help` | `wardrik_about`, `wardrik_doctor`, `docs_search`, `docs_read` |
| `*` | all of the above but `ops/` |

- A server that isn't added yet has no tools. [`GET .../definition`](/reference/http-api/#read-a-definition) lists it as `missing`.
- In `self/*`, `agents/*`, `ops/` and `settings`, reads have no default approval requirement.
  Changes need approval unless explicitly allowed. Policy rules still apply to both.
- Each acts with the agent's own [bindings](/run/orgs/#roles-and-bindings).
- `secret_request` never sees a value. It answers the dashboard page and the command where a
  person seals one.
- A created agent inherits the policy of the agent that created it.

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

- Backoff is exponential with jitter, starting under one second. A provider's `Retry-After`, in
  seconds, sets the wait instead, up to `max_wait`.
- A 4xx response other than 408, 425 and 429 isn't retried.

## model_options

```yaml
model_options: {temperature: 0.2, max_tokens: 4000, receive_timeout: 600}
```

| Key | Default | Description |
| --- | --- | --- |
| `temperature` | the model's | sampling temperature |
| `top_p` | the model's | nucleus sampling probability |
| `max_tokens` | the model's | maximum output tokens per response |
| `reasoning_effort` | the model's | `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` or `default` |
| `receive_timeout` | `300` | seconds a model call waits for an answer |
| `stream_idle_timeout` | `300` | maximum seconds between streamed responses |
| `total_timeout` | none | maximum total duration of a model call, in seconds |

- These merge over [`models.options`](/reference/config/#models) in `config.yaml`.
- No other key is accepted. Options such as `base_url` belong to the operator, since each call
  carries the deployment's API key.

## compaction

```yaml
compaction: {at: 0.6, keep: 0.25}
```

| Key | Default | Description |
| --- | --- | --- |
| `at` | `0.6` | fraction of the context window that triggers a summary |
| `keep` | `0.25` | fraction of the window kept verbatim |
| `window` | the catalog's, or `128000` | the context window in tokens |

## digest

```yaml
digest: false
```

- On by default. The agent writes a digest of each conversation before it sleeps, after
  `idle_timeout`. See [Digests](/concepts/files-and-memory/#digests).
- It needs the `files` tool. Without it, no digest is written.
- Each digest is a model call, and counts towards the agent's budget.

## triggers

```yaml
triggers:
  - name: sweep
    every: "*/30 * * * *"
    prompt: Check the incident queue.
  - name: launch
    at: "2026-11-17T09:00"
    timezone: America/Los_Angeles
    prompt: Publish the post in drafts/launch.md.
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
| `at` | | instead of `every`: a time to run once, like `2026-11-17T09:00`; removed after it runs |
| `timezone` | `Etc/UTC` | the IANA time zone for `every` or `at` |
| `prompt` | | the message sent to the agent |
| `prompt_file` | | instead of `prompt`, a workspace file to read the message from |
| `overlap` | `settle` | `skip`, `queue`, or `settle` a run while the agent is busy; `at` and webhooks default to `queue` |
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
