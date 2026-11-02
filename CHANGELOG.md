# Changelog

## 0.1.0-rc.2 (2026-11-02)

- Kinds that say what a secret is for: `:api_key`, `:client_secret`, `:header`,
  `:signing_secret` and `:token`, beside `:grant` and `:secret`. Each is sealed with its value.
- `fetch/4` takes `kind:`, and reads only a value of that kind.

### Breaking

- `put/3` takes a `WardrikVault.Secret`, and raises on an unknown `kind:`.
- `read/4` takes `keys:`. `WardrikVault.Sealed.seal/2` takes the value, then `:key`, `:path` and
  `:kind`.
- `WardrikVault.Grants` callbacks take a `WardrikVault.Grants.Request`, then their options.
- Implements the rc.2 `WardrikCore.Credentials` callbacks.

## 0.1.0-rc.1 (2026-10-30)

- `WardrikVault`, which keeps credentials sealed at rest with AES-256-GCM, in a `WardrikStore`.
- Keys that rotate: the first seals, any unseals.
- Credentials held by each `WardrikCore.Principal`. A tool reads only what its turn's principal
  holds.
- The vault as an agent's `WardrikCore.Credentials`. Its saved state holds only the vault's name.
- The deployment's own secrets, named in options as `{:secret, name}` and read on each use.
- Grants, like OAuth tokens, renewed or asked for through a `WardrikVault.Grants` module.
