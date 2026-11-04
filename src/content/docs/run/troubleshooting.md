---
title: Troubleshooting
description: "Diagnose with status, doctor and logs, then fix common problems."
sidebar:
  order: 9
---

```sh
wardrik status    # is it running?
wardrik doctor    # is the config valid?
wardrik logs      # tail the log
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

- `wardrik doctor` reads the same files as the daemon, so it works when the daemon won't start.
- Under systemd, the log is `journalctl --user -u wardrik -f`. Under `wardrik serve`, it's the
  terminal.

## Common problems

- **It doesn't start.** Run `wardrik doctor`. Usually `config.yaml` has a parse error, with the
  line number.
- **A `${NAME}` is unset.** Set it in `~/.config/wardrik/env` and restart. `vault put` needs a
  running daemon.
- **An agent file has an error.** `wardrik doctor` shows it. Fix it and `wardrik reload`.
- **An agent is missing a server's tools.** A new server in `config.yaml` needs a restart. A server
  that's down has no tools.
- **A policy change has no effect.** The daemon reads `policies/` at startup. Restart it.
- **The HTTP API doesn't respond.** Another process may be using port 4747. Set `http.port`.
- **An agent stopped replying.** `wardrik approval ls` lists its pending calls.
  `wardrik agent history AGENT` shows how its turns ended.
- **A trigger didn't run.** `wardrik trigger ls AGENT` shows its next run.
- **`404` for a resource that exists.** The token's user has no binding in its org. See
  [Orgs, roles and tokens](/run/orgs/).
- **A chat member is refused.** Map them under `channels.<name>.members`.
- **`wardrik` reports the daemon isn't started.** The command reads its token from
  `~/.local/share/wardrik/cli_token`, which the daemon writes on startup.
- **The service can't find a program `doctor` found.** systemd's `PATH` differs from your shell's.
  Use the full path.
