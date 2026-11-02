---
title: Home lab
description: "Watches your self-hosted services, reads the logs when one breaks, and restarts it once you approve."
sidebar:
  order: 4
---

This agent checks the containers on your home server every fifteen minutes. When one is down, it
reads the logs, says what went wrong, and proposes a fix you approve from your phone.

Needs [uv](https://docs.astral.sh/uv/), a daemon user that can reach Docker's socket, and a
[Slack app](/channels/slack/).

## The files

```yaml title="~/.config/wardrik/config.yaml"
mcp:
  docker:
    command: uvx
    args: [mcp-server-docker]

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    members: {U024BE7LH: user:admin}

notify:
  targets:
    homelab: {channel: slack, room: "#homelab"}
```

```yaml title="~/.config/wardrik/policies/homelab.yaml"
allow:
  - docker/list_*
  - docker/fetch_container_logs
ask:
  docker/stop_container: This stops a service.
  docker/start_container: This starts a service.
  docker/recreate_container: This recreates a container from its image.
deny:
  docker/remove_*: Nothing is deleted.
  docker/run_container: New containers are started by you.
  docker/build_image: Images are built by you.
budget: {usd: 0.50, per: day}
```

```markdown title="~/.config/wardrik/agents/homelab.md"
---
description: Keeps my home lab's containers running.
tools: [docker/*]
policy: homelab
notify: {to: [homelab], on: [parked, failed]}
triggers:
  - name: check
    every: 15m
    prompt: Check every container.
---
List the containers. If one has exited, keeps restarting, or is unhealthy, read its last 100 log
lines and say in two sentences what went wrong. Then propose the smallest fix: restart it, or
recreate it from its image. If everything is fine, answer "All good."
```

## Try it

```sh
systemctl --user restart wardrik    # reads config.yaml and policies/
docker stop jellyfin
wardrik ask homelab "Check every container."
```

`#homelab` gets what it found, and a call to start `jellyfin` again with **Approve** and **Deny**.
After editing only an agent file, `wardrik reload` is enough.

## What it shows

- `notify` sends only waiting calls and failures, so a healthy check stays quiet.
- Docker access is root on the machine, so every change waits and anything destructive is refused.
- Logs are outside content: nothing in one gets the agent to act alone.
- A turn cut off by a power cut carries on when the daemon starts. See
  [Durable runs](/concepts/agents/#durable-runs).
