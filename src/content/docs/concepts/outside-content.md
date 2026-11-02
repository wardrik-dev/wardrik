---
title: Content from outside
description: "After an agent reads untrusted content, every call that changes something needs approval."
sidebar:
  order: 4
---

After a turn reads content from outside, every [gated](/concepts/policy/#gated-tools) call needs
approval, even if `allow` matches it. The content may have prompted the call.

> github/create_issue is allowed, but this run has read content from outside, which may be what
> asked for it.

Content from outside comes from:

- `web_search`, and `deep_research` when its researchers read it;
- MCP servers not marked `trusted: true`;
- tool workers, unless `http.trusted_workers: true`;
- a file written by a turn that had read outside content.

The conversation keeps the `outside` label until `wardrik agent clear AGENT`.

## Allowing after content from outside

`allow_after` keeps a gated tool allowed after the label. Use it for tools that do no harm if misused:

```yaml
allow: [linear/*]
allow_after:
  outside: [github/add_labels]
```

- An `ask` or `deny` still takes precedence.
- A message sent with `agent_ask` copies the sender's labels to the receiver.
- `wardrik approval ls` marks such calls `[after content from outside]`. HTTP returns
  `labels: ["outside"]`.
