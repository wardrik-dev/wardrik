---
title: Troubleshooting
description: "Three commands answer most questions: status, doctor and logs. Then the common problems and their fixes."
sidebar:
  order: 8
---

```sh
wardrik status    # does it run?
wardrik doctor    # will its config work?
wardrik logs      # what did it say?
```

```text
ok    env            /home/me/.config/wardrik/env sets 3 variables
ok    config         /home/me/.config/wardrik/config.yaml reads
ok    storage        keeps everything on this node's disk, under /home/me/.local/share/wardrik/store
ok    vault          1 key from /home/me/.local/share/wardrik/vault_key, which seals
ok    mcp github     answers at api.githubcopilot.com:443
FAIL  mcp notes      runs npx, which isn't on this machine's PATH
ok    agents         2 agent files and 1 policy read
```

- `wardrik doctor` reads what the daemon reads, so it works on a daemon that won't start.
- Under systemd, the log is `journalctl --user -u wardrik -f`. Under `wardrik serve`, it's the
  terminal.

## Common problems

- **It doesn't start.** Run `wardrik doctor`. Usually `config.yaml` doesn't read, and the line says
  where.
- **A `${NAME}` nothing sets.** Set it in `~/.config/wardrik/env` and start again. `vault put`
  needs a running daemon.
- **An agent file isn't running as written.** `wardrik doctor` says why. Fix it and `wardrik reload`.
- **An agent lacks a server's tools.** A new server in `config.yaml` needs a restart. A server
  that's down offers none.
- **A policy change didn't take.** The daemon reads `policies/` as it starts. Restart it.
- **The HTTP API doesn't answer.** Another process may hold 4747. Set `http.port`.
- **An agent stopped answering.** `wardrik approval ls` shows what it waits on.
  `wardrik agent history AGENT` shows how its turns ended.
- **A trigger didn't run.** `wardrik trigger ls AGENT` shows when it runs next.
- **`404` for something that's there.** The token's user has no binding in its org. See
  [Orgs, roles and tokens](/run/orgs/).
- **A chat member is refused.** Map them under `channels.<name>.members`.
- **`wardrik` says the daemon hasn't started.** It reads its token from
  `~/.local/share/wardrik/cli_token`, written as the daemon starts.
- **A program `doctor` finds isn't found by the service.** systemd's `PATH` isn't your shell's.
  Name it by its full path.
