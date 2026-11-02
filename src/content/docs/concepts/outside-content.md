---
title: Content from outside
description: "Once an agent reads a stranger's words, every call that changes something waits for a person."
sidebar:
  order: 4
---

Once a turn reads content from outside, every [gated](/concepts/policy/#gated-tools) call waits
for a person, whatever `allow` says. What it read may be what asked for the call.

> github/create_issue is allowed, but this run has read content from outside, which may be what
> asked for it.

Content from outside comes from:

- `web_search`, and `deep_research` when its researchers read it;
- MCP servers not marked `trusted: true`;
- tool workers, unless `http.trusted_workers: true`;
- a file written by a turn that had read outside content.

The label stays with the conversation until `wardrik agent clear AGENT` empties it.

## Allowing after content from outside

`allow_after` keeps a gated tool allowed after the label. Use it for tools a stranger can't misuse:

```yaml
allow: [linear/*]
allow_after:
  outside: [github/add_labels]
```

- An `ask` or `deny` still wins.
- A message one agent sends another with `agent_ask` carries the sender's labels.
- `wardrik approval ls` marks a held call `[after content from outside]`. HTTP gives
  `labels: ["outside"]`.
