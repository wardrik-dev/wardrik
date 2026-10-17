---
title: A server of its own
description: "Put one team's daemon on its own server with deploy/single/up.sh: Caddy in front, a Slack app from the manifest."
sidebar:
  order: 0
---

One daemon on one server serves one team. `deploy/single/up.sh`, run from a checkout on your
machine, puts it there over SSH, and again with each new release.

Give each team its own server and a subdomain of yours, such as `acme.example.com`. The team's DNS
is never touched, and the address browsers return to when they connect an account stays yours.

## What you need

- **The server:** Ubuntu 24.04 or Debian 12, x86_64 or aarch64, reachable over SSH as root or as a
  user with passwordless sudo.
- **The name:** the team's subdomain pointing at the server, with ports 22, 80 and 443 open. Caddy
  gets a certificate for it; see [A public address](/run/public-address/).
- **Your machine:** the checkout, SSH and Docker. Docker builds the release on the oldest Linux it
  runs on, so it runs on the server whatever your machine is.

The script makes the daemon's user and installs Caddy, so the server needs nothing else.

## Put it on the server

1. Make the team's [Slack app](/channels/slack/#a-slack-app) from the manifest, with
   `acme.example.com` as its address, and keep its bot token and signing secret. Slack checks the
   address once the daemon runs, under **Event Subscriptions**.
2. Write the team's env file, readable by you alone:

   ```sh title="~/customers/acme/env"
   SLACK_BOT_TOKEN=xoxb-...
   SLACK_SIGNING_SECRET=...
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

   It ends by running `wardrik status` and `wardrik doctor` on the server.

4. Invite the app to a channel with `/invite @yourapp`. The example agent answers there, and the
   channel's approvers decide what it waits on.
5. Add the team's [MCP servers](/build/mcp/) to `config.yaml`, and each account they sign in with
   under `oauth.providers`; see [Connect accounts](/build/accounts/). `wardrik doctor` says whether
   `acme.example.com/oauth` reaches the daemon.

## Change its config

`WARDRIK_ORG`, `WARDRIK_MODEL` and `WARDRIK_APPROVERS` write `config.yaml` the first time only.
After that, edit it on the server and restart:

```sh
ssh wardrik@203.0.113.7
nano ~/.config/wardrik/config.yaml
systemctl --user restart wardrik
wardrik doctor
```

Agent and policy files need only `wardrik reload`.

## Ship a new release

Run the script again with the same variables. It builds from the checkout as it is, installs the
release beside the running one, and restarts the daemon on it. The store, the vault and the config
stay, and so does the release before; see [Upgrade and back up](/run/upgrade-and-back-up/).

## Back it up

Everything the team has is in `~wardrik/.local/share/wardrik` on the server: conversations,
connected accounts and the vault, with the vault's key beside the store. A rented server's disk
goes when the server does. Back up that directory, or keep the store elsewhere with
[Storage](/run/storage/).

Give the vault its own key in the env file too. A server rebuilt over the same store can then read
what the last one sealed.

## Details

### What the script leaves on the server

| Where | What | Run again |
| --- | --- | --- |
| The user `wardrik` | Runs `wardrik.service` under its own systemd, from boot. The keys that log you in as `WARDRIK_HOST` log you in as `wardrik` too. | Kept, with keys added |
| `~wardrik/.local/lib/wardrik` | The release from `deploy/install.sh`, and the one before | The new release, then a restart |
| `~wardrik/.config/wardrik/env` | Your env file | Replaced by yours |
| `~wardrik/.config/wardrik/config.yaml` | The org, model and policy, the callback's address, the Slack channel and its approvers | Kept |
| `~wardrik/.config/wardrik/agents`, `policies` | An example agent offered in Slack, and the policy every agent gets | Kept; a missing file is put back |
| `~wardrik/.local/share/wardrik` | The store, and the vault's key unless the env file sets `WARDRIK_VAULT_KEY` | Kept |
| `/etc/caddy/Caddyfile` | `/oauth/`, `/v1/hooks/` and `/v1/channels/` passed to the daemon; 404 for anything else | Written again |

### More variables

- `WARDRIK_TARBALL` installs a release tarball you already have, instead of building one.
- `WARDRIK_SSH_OPTS` passes more options to ssh and scp, such as `-o Port=2200`.

Each team's env file stays on your machine, and every run copies it over the server's.
