---
title: A server of its own
description: Put one team's daemon on a server of its own, from a checkout, with Caddy in front for connecting accounts and a Slack app made from a manifest.
sidebar:
  order: 0
---

One daemon on one server serves one team: its agents, its Slack workspace, the accounts it connects.
`deploy/single/up.sh`, in a checkout, puts it there from your machine over SSH, and puts it there
again with each new release.

Rent a server for each team, and give each one a subdomain of a domain of yours, such as
`acme.example.com`. Nothing is then asked of the team's own DNS, and the address their browsers come
back to when they connect an account stays yours. Keep each team's secrets in an env file of its
own on your machine, which every run copies to the server in place of what is there.

## What the server needs

- Ubuntu 24.04 or Debian 12, on x86_64 or aarch64, which SSH reaches as root or as a user sudo lets
  do anything without a password.
- The team's subdomain pointing at it, and ports 22, 80 and 443 open to it. Caddy gets the name a
  certificate, so that people's browsers come back to the daemon over HTTPS when they
  [connect an account](/guides/accounts/); see [A public address](/operate/public-address/).
- Nothing else: the script makes the user the daemon runs as, and installs Caddy.

Your own machine needs the checkout, SSH, and Docker, which builds the release in the Dockerfile's
`tarball` stage, on the oldest Linux the release runs on, so it runs on the server whatever your
machine is.

## Steps

1. Make the team's [Slack app](/channels/slack/#a-slack-app) from the manifest, and keep its two
   tokens.
2. Write the team's env file, readable by you alone, with those tokens and the model's key:

   ```sh title="~/customers/acme/env"
   SLACK_BOT_TOKEN=xoxb-...
   SLACK_APP_TOKEN=xapp-...
   ANTHROPIC_API_KEY=sk-ant-...
   ```

3. Run the script from the checkout:

   ```sh
   WARDRIK_HOST=root@203.0.113.7 \
   WARDRIK_DOMAIN=acme.example.com \
   WARDRIK_ENV_FILE=~/customers/acme/env \
   WARDRIK_ORG=acme \
   WARDRIK_APPROVERS="@maria, jon@example.com" \
     deploy/single/up.sh
   ```

   It ends with `wardrik status` and `wardrik doctor` on the server.

4. Invite the Slack app to a channel, `/invite @yourapp`. The example agent answers there, and the
   channel's approvers are asked what it waits on.
5. Give the agents the team's tools: their [MCP servers](/guides/mcp/) in `config.yaml`, and under
   `oauth.providers` each account those servers sign in with, as
   [Connect accounts](/guides/accounts/) says. The daemon serves `acme.example.com/oauth` once a
   provider is named, and `wardrik doctor` says whether it reaches the daemon.

## What it leaves on the server

| Where | What | Run again |
| --- | --- | --- |
| The user `wardrik` | Runs the daemon as `wardrik.service` under its own systemd, from boot. The keys that let you in as `WARDRIK_HOST` let you in as `wardrik` too. | Kept, with keys added |
| `~wardrik/.local/lib/wardrik` | The release, installed by `deploy/install.sh`, and the one before it | The new release, then a restart |
| `~wardrik/.config/wardrik/env` | Your env file | Replaced by yours |
| `~wardrik/.config/wardrik/config.yaml` | The org, the agents' model and policy, the callback's address, the Slack channel and its approvers | Kept: change it on the server |
| `~wardrik/.config/wardrik/agents`, `policies` | An example agent offered in Slack, and the policy every agent is given | Kept, and a file missing is put back |
| `~wardrik/.local/share/wardrik` | The store, and the vault's key unless the env file sets `WARDRIK_VAULT_KEY` | Kept |
| `/etc/caddy/Caddyfile` | `/oauth/` on the domain passed on to the daemon, and a 404 for anything else | Written again |

The variables `WARDRIK_ORG`, `WARDRIK_MODEL` and `WARDRIK_APPROVERS` write `config.yaml` the first
time only. From then on, change it on the server, and start the daemon again:

```sh
ssh wardrik@203.0.113.7
nano ~/.config/wardrik/config.yaml
systemctl --user restart wardrik
wardrik doctor
```

Agent and policy files are read again with `wardrik reload`, without a restart.

## A new release

Run the script again, with the same variables. It builds the release from the checkout as it is,
installs it beside the one running, and starts the daemon again on it, keeping the store, the vault
and the config. The release before stays installed, to go back to; see
[Upgrade and back up](/operate/upgrade-and-back-up/).

`WARDRIK_TARBALL` installs a release tarball you already have rather than building one, and
`WARDRIK_SSH_OPTS` passes ssh and scp more options, such as `-o Port=2200`.

## Backing it up

Everything the team has, its conversations, connected accounts and the vault, is in
`~wardrik/.local/share/wardrik` on the server, with the vault's key beside the store. On a rented
server that is the server's own disk, which goes when the server does. Back up the
directory, or keep the store elsewhere with [Storage](/operate/storage/), and give the vault a key of
its own in the env file, so that a server made again over the same store reads what the last one
sealed.
