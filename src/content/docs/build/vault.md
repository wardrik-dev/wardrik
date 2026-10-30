---
title: Keep secrets in the vault
description: "Seal API keys and tokens in the vault, for a user or an org, so no file holds a secret."
sidebar:
  order: 2.5
---

The vault keeps secrets sealed in the store, so no file holds them.

```sh
echo "$PD_TOKEN" | wardrik vault put pagerduty --org acme   # acme's agents'
echo "$SENTRY" | wardrik vault put sentry --user jon        # jon's agents', in the deployment's org
echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY           # the deployment's own
wardrik vault ls --org acme                                 # names and kinds, never values
wardrik vault rm pagerduty --org acme
```

`vault put` reads the value from stdin, and needs the daemon running. Each command takes one owner:

| Flag | Owner |
| --- | --- |
| none | the deployment |
| `--org ORG` | the org `ORG` |
| `--user USER` | the user `USER` in the deployment's org |

`vault ls` lists one owner's secrets. Its `KIND` column says `secret` for one you put, and `grant`
for an account a person [connected](/build/accounts/).

## Whose secret a tool reads

A tool reads a secret by name, as the agent's owner holds it:

- A user's agent reads that user's secrets and connected accounts.
- An org's agent reads the org's.

Nothing falls back from one owner to another. A user's agent that needs the org's account asks the
org's agent, which the org's policy holds.

A secret the owner holds is found before an OAuth provider of the same name is asked. So a sealed
token stands in for an account the owner would otherwise [connect](/build/accounts/).

## Model keys fall back

A model provider's key is the exception. Wardrik looks for it by its name, such as
`ANTHROPIC_API_KEY`, in this order:

1. The user, for a user's agent.
2. The org.
3. The deployment.
4. The daemon's environment.

So an org brings its own model key by sealing it under the provider's key name:

```sh
echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY --org acme
```

## The deployment's secrets

A secret put with no owner is the deployment's. The daemon uses it for:

- a `${NAME}` in `config.yaml` that the environment doesn't set, such as
  [`brave.api_key`](/reference/config/#brave);
- a model provider's key, when no user or org holds one.

No agent's tool reads it. For a tool token every org's agents use, seal it for each org:

```sh
echo "$PD_TOKEN" | wardrik vault put PAGERDUTY_TOKEN --org acme
echo "$PD_TOKEN" | wardrik vault put PAGERDUTY_TOKEN --org globex
```

## The vault's key

The daemon makes a key the first time it starts, in `~/.local/share/wardrik/vault_key`. It looks
for the key in this order:

1. `vault.keys` in `config.yaml`.
2. `WARDRIK_VAULT_KEY` in the daemon's environment, or its env file `~/.config/wardrik/env`.
3. `vault_key` in the data home, made if it's missing.

To make a key yourself:

```sh
openssl rand -base64 32 > ~/.local/share/wardrik/vault_key
systemctl --user restart wardrik
```

Keep the key out of the store's backups. With both, every secret can be read.

## Change the key

`vault.keys` takes several. The first seals, and any of them opens:

```yaml
vault:
  keys: ["${WARDRIK_VAULT_KEY_NEW}", "${WARDRIK_VAULT_KEY}"]
```

To move off the key the daemon made, set `WARDRIK_VAULT_KEY` to what `vault_key` holds. Then list
the new key first.

## Details

- The daemon reads its keys as it starts, so restart it after making or changing one.
- `vault`, `http` and `storage` in `config.yaml` take `${NAME}` from the environment only, since
  they're read before the vault opens.
- A key is 32 bytes, base64-encoded. A key that isn't is dropped with a warning.
- Without a key, nothing is sealed or read, and every call that needs a connected account fails.
  Nothing falls back to plain text.
- A token is sealed with the new key the next time it's refreshed. A secret is sealed with it the
  next time you put it. Once a key is removed, a token sealed with it isn't read, and its user
  connects again.
- Names aren't sealed. Anyone who can read the store sees who holds a secret of which name.
