---
title: Content from outside
description: "Once an agent reads a stranger's words, every call that changes something waits for a person."
sidebar:
  order: 5
---

A turn carries a label for what it has read. Content from outside the deployment is labelled
`outside`. It comes from:

- `web_search` and `deep_research`;
- MCP servers not marked `trusted: true`;
- tool workers, unless `http.trusted_workers: true`;
- a file written by a turn that had read outside content.

Once a turn carries `outside`, every [gated](/concepts/rules/#gated-tools) call waits for a person, whatever `allow` says. What it
read may be what asked for the call. The person is told so:

> github__create_issue is allowed, but this run has read content from outside, which may be what
> asked for it.

The label stays with the conversation until `wardrik clear AGENT` empties it.

## Allowing after content from outside

An agent that reads outside content, reaches private data and changes things needs a person; any
two of those are safe. `allow_after` allows a gated tool even after a label, for tools a stranger
can't misuse:

```yaml
allow: [linear/*]
allow_after:
  outside: [github/add_labels]
```

An `ask` or `deny` still wins over it.

## Details

### When a turn is held

The `outside` label counts from the model's next round of calls. `DELETE
/v1/agents/{key}/conversation` clears it too. A label that `allow_after` names holds gated calls the
way `outside` does; a label no rule names is carried and shown, but holds nothing. A definition sent
over the HTTP API can name a policy that uses `allow_after`, but can't write the rule itself.
