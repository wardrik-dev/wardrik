---
title: Home lab
description: "Watches your self-hosted services, reads the logs when one breaks, and restarts it once you approve."
sidebar:
  order: 4
---

Run Wardrik on the box under your desk, and this agent keeps an eye on everything else running
there. Every fifteen minutes it checks your containers. When one is down or unhealthy, it reads the
logs, tells you what went wrong, and proposes the fix: restart it, or recreate it. You approve from
your phone.

Reading runs alone. Stopping, starting and recreating wait for you. Deleting is refused.

## What it takes

- the daemon, [installed](/getting-started/install/) as a service, with a model provider's key;
- [uv](https://docs.astral.sh/uv/) for the Docker server, and a daemon user that can reach Docker's
  socket;
- a [Slack app](/channels/slack/#a-slack-app) in a workspace of your own, and a channel for it,
  here `#homelab`.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
mcp:
  docker:
    command: uvx
    args: [mcp-server-docker]

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}

notify:
  homelab:
    channel: slack
    room: "#homelab"
```

The [Docker server](https://github.com/ckreiling/mcp-server-docker) talks to the local Docker
daemon. For a remote one, set `DOCKER_HOST` under the server's `env`.

### The policy

```yaml title="~/.config/wardrik/policies/homelab.yaml"
allow:
  - docker/list_containers
  - docker/fetch_container_logs
  - docker/list_images
  - docker/list_volumes
  - docker/list_networks
ask:
  docker/stop_container: This stops a service.
  docker/start_container: This starts a service.
  docker/recreate_container: This recreates a container from its image.
deny:
  docker/remove_*: Nothing is deleted.
  docker/run_container: New containers are started by you.
  docker/build_image: Images are built by you.
  docker/push_image: Images are pushed by you.
budget:
  usd: 0.50
  per: day
```

- The Docker server has no restart tool: a restart is a stop, then a start. Each waits for you.
- Container logs are written by the programs in them, and by whoever sent those programs requests,
  so they're outside content. Nothing in a log can get the agent to act on its own.

### The agent

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
You look after the containers on my home server. On each check, list them. If one has exited,
keeps restarting, or reports unhealthy, read its last 100 log lines and say in two sentences what
went wrong. Then propose the smallest fix: restart it, or recreate it from its image.

If everything is fine, answer "All good." and nothing else.
```

`notify` sends only waiting calls and failures, so a healthy check stays quiet.

## Try it

```sh
wardrik reload
docker stop jellyfin
wardrik ask homelab "Check every container."
```

`#homelab` gets what it found and a waiting call to start `jellyfin` again, with **Approve** and
**Deny**.

## What it shows

- **A quiet watcher:** a check every fifteen minutes that speaks only when something's wrong.
- **Fixes you approve** from your phone, with the call's arguments in front of you.
- **It survives a reboot.** A turn interrupted by a power cut carries on when the daemon starts
  again. A stop that had begun but not finished asks you again, rather than running twice. See
  [Durable runs](/concepts/durable-runs/).

## Details

### Docker access

The daemon runs as your user, so that user needs Docker access, usually by being in the `docker`
group. That is root-equivalent on the machine, which is why every change waits for you, and
anything that deletes, builds or runs a new container is refused.

### Taking it further

- Add Home Assistant's [MCP server](https://www.home-assistant.io/integrations/mcp_server/), at
  `/api/mcp` on your Home Assistant, and let it turn things on and off: its tools include
  `intent__HassTurnOn` and `intent__HassTurnOff`.
- Back up before each recreate: give it a tool in your own code that snapshots a volume. See
  [Tools in your app](/build/tool-workers/).
