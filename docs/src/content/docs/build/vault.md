---
title: Keep secrets in the vault
description: "Seal API keys and tokens in the vault, for a user or an org, so no file holds a secret."
sidebar:
  order: 2.5
---

The vault keeps secrets sealed with AES-256-GCM in the store, so every node of a cluster can use
them. An agent's tools read a secret by name, as its owner holds it.

```sh
wardrik vault put pagerduty --org acme     # acme's own agents'
wardrik vault put sentry --user jon        # jon's agents', in the deployment's org
wardrik vault ls                           # what it holds, and whose, never the values
wardrik vault rm pagerduty --org acme
```

`vault put NAME` asks for the value without showing it, or reads it from a pipe. `--org ORG` with
`--user USER` puts one for a user outside the deployment's org. The org must be one `config.yaml`
declares; see [Orgs](/run/orgs/#declare-an-org). `vault ls` lists the accounts users
connected too.

## Whose secret

An agent reads only what its owner holds. An agent that works for a user reads that user's secrets
and accounts; an org's agent reads the org's. Nothing falls back from one to the other, so a user's
agent that needs the org's account asks the org's agent, which its own policy holds.

A secret the owner holds is found before an OAuth provider of the same name is asked for, so it
stands in for an account they would otherwise [connect](/build/accounts/).

## The deployment's secrets

A secret put with no owner is the deployment's, for the daemon's own use: a model provider's key, or
a `${NAME}` in `config.yaml`. No agent's call reads it. For a key every org's agents use, such as a
search tool's, seal it for each org:

```sh
wardrik vault put SEARCH_API_KEY --org acme
wardrik vault put SEARCH_API_KEY --org globex
```

A user's own agents read only what the user holds, so each user who needs it seals their own.

## The vault's key

The vault needs a key before it can seal anything. The first `wardrik vault put` offers to make one,
and keeps it in `~/.local/share/wardrik/vault_key`, beside the store. To make it yourself:

```sh
openssl rand -base64 32 > ~/.local/share/wardrik/vault_key
systemctl --user restart wardrik
```

To keep the key apart from the store, set `WARDRIK_VAULT_KEY` in the daemon's environment, such as
`~/.config/wardrik/env`, or `vault.keys` in `config.yaml`. Keep the key out of the store's backups:
with it and the store, every secret can be read.

## Changing the key

`vault.keys` takes several. The first seals, and any of them opens:

```yaml
vault:
  keys: ["${WARDRIK_VAULT_KEY_NEW}", "${WARDRIK_VAULT_KEY}"]
```

To change the key the daemon made, set `WARDRIK_VAULT_KEY` to what `vault_key` holds, and list the
new key first.

## Details

- The daemon reads the key as it starts, so restart it after making or changing one.
- `vault.keys` and `WARDRIK_VAULT_KEY` are used in place of `vault_key`.
- Without a key nothing is sealed or read, and every call needing a connected account fails;
  nothing falls back to plain text.
- Without the key, what the vault sealed can't be read.
- A token is sealed with the new key the next time it is refreshed, and a secret the next time you
  put it. Once a key is removed, a token sealed with it isn't read, and its user connects again.
- Each secret is kept under its owner as the owner reads: `deployment/NAME`, `acme/NAME`, or a
  user's namespace, `acme/@jon`. Secrets kept before the vault named owners this way, the
  deployment's under `_/NAME` and users' under a hash of who they are, aren't read: after
  upgrading, `wardrik vault put` them again, and users connect their accounts again.
