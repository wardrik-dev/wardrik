---
title: Keep secrets in the vault
description: "Seal API keys and tokens in the vault, for the deployment, an org or a person, so no file holds a secret."
sidebar:
  order: 2.5
---

The vault seals secrets in the store, so no file holds them:

```sh
echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY --for api_key           # the deployment's
echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY --org acme --for api_key # acme's
echo "$CRM" | wardrik vault put CRM_KEY --user jon --for header           # acme/@jon's, in the deployment's org
wardrik vault ls --org acme                                              # names and purposes, never values
wardrik vault rm CRM_KEY --user jon
```

- `vault put` reads the value from stdin. The daemon must be running.
- No flag is the deployment. `--org ORG` is an org. `--user NAME` is a person in the deployment's
  org.

## What a secret is for

Each secret is sealed `--for` one purpose, and read only for that:

| `--for` | Read as |
| --- | --- |
| `api_key` | a key a model or tool calls a service with |
| `client_secret` | an OAuth app's client secret, for `wardrik provider add --secret` |
| `header` | an MCP server's header, for `wardrik server add --secret` |
| `signing_secret` | a webhook's signing secret, for `wardrik notify add --secret` and triggers |

## API keys

An agent's model and tools look for a key by its name, as `ANTHROPIC_API_KEY`:

1. Its owner's: a person, or its org.
2. The person's org.
3. The deployment's, while `deployment_keys` is `true` (the default).
4. The daemon's environment.

So an org brings its own key by sealing it under the key's name. Set `deployment_keys: false` in
`config.yaml` to make every org bring its own.

## The deployment's secrets

- `${NAME}` in `config.yaml` reads the environment, the env file, then the deployment's secret
  `NAME`.
- No agent reads them, except API keys while `deployment_keys` is `true`.

## The vault's key

The daemon looks for its key in this order:

1. `vault.keys` in `config.yaml`.
2. `WARDRIK_VAULT_KEY` in the environment, or in `~/.config/wardrik/env`.
3. `~/.local/share/wardrik/vault_key`, made the first time the daemon starts.

To change it, list the new key first. The first seals, and any of them opens:

```yaml
vault:
  keys: ["${WARDRIK_VAULT_KEY_NEW}", "${WARDRIK_VAULT_KEY}"]
```

## Details

- Restart the daemon after changing a key.
- A key is 32 random bytes, base64-encoded: `openssl rand -base64 32`.
- Keep the key out of the store's backups. With both, every secret can be read.
- Without a key, nothing is sealed, and calls that need a connected account fail.
- Names aren't sealed. Anyone who can read the store sees who holds a secret of which name.
- Over HTTP, secrets are at `/v1/owners/{owner}/secrets`. `{owner}` is one URL-encoded segment, as
  `acme%2F%40jon`.
