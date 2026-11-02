# Changelog

## 0.1.0-rc.2 (2026-11-01)

- Kinds that say what a secret is for: `:api_key`, `:client_secret`, `:header`,
  `:signing_secret` and `:token`, beside `:grant` and `:secret`. Each is sealed with its value, so
  it can't be relabelled.
- `fetch/4` takes `kind:`, and reads a value only of that kind, so a client secret is never read
  as an API key.

### Breaking

- `put/5` raises on a kind it doesn't know.
- `put/3` takes the principal, name and value as a `WardrikVault.Secret`, so the name and value
  can't swap. `read/4` takes the keys as `keys:`, after the principal and name, and
  `WardrikVault.Sealed.seal/2` the value, then `:key`, `:path` and `:kind`.
- `WardrikVault.Grants` callbacks take a `WardrikVault.Grants.Request`, then their options:
  `renew/2`, `ask/2` and `refused/2`. The vault implements `WardrikCore.Credentials` rc.2's
  `resolve/2` and `refused/2`.

## 0.1.0-rc.1 (2026-10-30)

- `WardrikVault`, which keeps credentials sealed at rest with AES-256-GCM, in a `WardrikStore`.
- Keys that rotate: the first seals, any unseals.
- Credentials held by each `WardrikCore.Principal`. A tool reads only what its turn's principal
  holds.
- The vault as an agent's `WardrikCore.Credentials`. Its saved state holds only the vault's name.
- The deployment's own secrets, named in options as `{:secret, name}` and read on each use.
- Grants, like OAuth tokens, renewed or asked for through a `WardrikVault.Grants` module.
