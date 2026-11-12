---
title: Home lab
description: "Checks your self-hosted containers, reads the logs when one fails, and restarts it after you approve."
sidebar:
  order: 4
---

Check your home server’s containers every 15 minutes. If one fails, the agent reads its logs,
reports a likely cause, and proposes a restart or recreation for you to approve in Slack.

Requires [uv](https://docs.astral.sh/uv/), a daemon user with access to the Docker socket, and a
[Slack app](/build/slack/).

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

`#homelab` shows the findings and a `start_container` call for `jellyfin`, with **Approve** and
**Deny**. After editing only an agent file, `wardrik reload` is enough.

## How it works

- `notify` sends only pending calls and failures, so healthy checks post nothing.
- Docker socket access grants extensive control over the host. The policy requires approval
  for changes and denies destructive operations.
- Logs are untrusted content, so gated calls require approval after the agent reads them.
- A turn interrupted by a power loss resumes when the daemon starts. See
  [Durable runs](/concepts/agents/#durable-runs).
