---
title: The terminal client
description: "Watch agents, talk to them, and decide what they wait on from your terminal with the wardrik command."
sidebar:
  order: 8
---

Wardrik has no separate terminal client. The `wardrik` command does the same work from your shell:

```sh
wardrik ls                                          # 1. every agent, its status and spend
wardrik ask triage "What came in overnight?"        # 2. send a message
wardrik follow triage                               # 3. watch its turns as they happen
wardrik approval ls                                 # 4. the calls waiting on a person
wardrik approval approve triage call_1 --note "ok"  # 5. let one run
wardrik approval deny triage call_2 --reason "no"   # 6. or refuse it
```

`wardrik help` lists every command. See [the CLI reference](/reference/cli/).
