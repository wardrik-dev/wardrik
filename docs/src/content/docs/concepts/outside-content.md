---
title: Untrusted content
description: "Require approval for gated tool calls after an agent reads untrusted content."
sidebar:
  order: 4
---

After an agent reads untrusted content, Wardrik labels the conversation `outside`. Every
[gated tool call](/concepts/policy/#gated-tools) then requires approval, even if an `allow` rule
matches. This prevents instructions in tool results from authorizing changes.

For example, an agent may be allowed to create GitHub issues. After it reads untrusted content,
creating an issue requires approval.

Wardrik treats these sources as untrusted:

- `web_search`, and `deep_research` when its researchers read it;
- MCP servers not marked `trusted: true`;
- tool workers, unless `http.trusted_workers: true`;
- files written during turns that read untrusted content.

The conversation keeps the `outside` label until `wardrik agent clear AGENT`.

## Allow selected tools after reading untrusted content

Use `allow_after` to let selected tools run without approval after the agent reads untrusted
content. Limit exceptions to actions whose effects you are willing to accept:

```yaml
allow: [linear/*]
allow_after:
  outside: [github/add_labels]
```

- An `ask` or `deny` still takes precedence.
- A message sent with `agent_ask` copies the sender's labels to the receiver.
- `wardrik approval ls` marks such calls `[after content from outside]`. HTTP returns
  `labels: ["outside"]`.
