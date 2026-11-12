---
title: Keep secrets in the vault
description: "Store API keys and tokens encrypted in the vault, for the deployment, an org or a user, instead of in files."
sidebar:
  order: 2.5
---

Store API keys, tokens, and other credentials in Wardrik’s encrypted vault. Pass secret values
through stdin so you can reference them by name in configuration:

```sh
echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY --for api_key           # the deployment's
echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY --org acme --for api_key # acme's
echo "$CRM" | wardrik vault put CRM_KEY --user jon --for header           # acme/@jon's, in the deployment's org
wardrik vault ls --org acme                                              # names and purposes, never values
wardrik vault rm CRM_KEY --user jon
```

- `vault put` reads the value from stdin. The daemon must be running.
- With no flag, the secret belongs to the deployment. `--org ORG` sets an org. `--user NAME` sets
  a user in the deployment's org.

## Purposes

The `--for` flag restricts how a secret can be used:

| `--for` | Used as |
| --- | --- |
| `api_key` | an API key for model providers or tool services |
| `client_secret` | an OAuth app's client secret, for `wardrik provider add --secret` |
| `header` | an MCP server's header, for `wardrik server add --secret` |
| `signing_secret` | a webhook's signing secret, for `wardrik notify add --secret` and triggers |

## API keys

An agent's model and tools look up a key by name, such as `ANTHROPIC_API_KEY`, in order:

1. The agent owner's secrets: a user's or an org's.
2. The user's org.
3. The deployment's, if `deployment_keys` is `true` (the default).
4. The daemon's environment.

To use an organization’s own API key, store it under the expected name, such as `ANTHROPIC_API_KEY`.
Set `deployment_keys: false` to prevent fallback to deployment vault keys.

## The deployment's secrets

`config.yaml` reads them as [`${NAME}`](/reference/config/). Agents can't read them, except API
keys while `deployment_keys` is `true`.

## The vault key

The daemon reads its key from, in order:

1. `vault.keys` in `config.yaml`.
2. `WARDRIK_VAULT_KEY` in the environment, or in `~/.config/wardrik/env`.
3. `~/.local/share/wardrik/vault_key`, generated on first start.

To rotate it, list the new key first. Wardrik encrypts new values with the first key and can decrypt existing values with any listed key:

```yaml
vault:
  keys: ["${WARDRIK_VAULT_KEY_NEW}", "${WARDRIK_VAULT_KEY}"]
```

## Details

- Restart the daemon after changing a key.
- A key is 32 random bytes, base64-encoded: `openssl rand -base64 32`.
- Back up the key separately from the store. Together they decrypt every secret.
- If no vault key is available, Wardrik cannot store secrets, and calls requiring a connected account fail.
- Names aren't encrypted. Anyone who can read the store sees which owner has which secret names.
- Over HTTP, secrets are at `/v1/owners/{owner}/secrets`. `{owner}` is one URL-encoded segment,
  such as `acme%2F%40jon`.
