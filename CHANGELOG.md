# Changelog

## 0.1.0-rc.2 (2026-10-31)

- `config.yaml` is checked against each library's own NimbleOptions schema, so it takes every
  option they do, and an error says where it is:

  ```
  config.yaml: oauth.providers.google: unknown options [:colour], valid options are: [:issuer, ...]
  ```

- New keys:
  - `deployment_keys`, `true` unless set, so agents use the API keys sealed in the deployment's
    vault where their owners and orgs hold none. See `WardrikDaemon.Keys`. Also `deployment`,
    `idle_timeout`, `retention` and `triggers`.
  - `oauth`: `client_name` and `req_options`, and a provider's `authorization_params`.
  - `channels`: `offering`, `deciding` and `req_options`.
  - `notify`: `retries` and `req_options`, and a webhook's `req_options`.
  - `mcp`: `cost`.
- `oauth` starts sign-ins whenever it's set, even with no `providers`, so orgs and people can add
  their own over the HTTP API.
- `roles` and `bindings` say who may do what, in which org, as Kubernetes RBAC does. An agent gets
  its own bindings, never its owner's; everyone may do anything to what they own; a chat member
  decides only what they asked, or as an approver. See `WardrikDaemon.Authorizer`.
- The daemon keeps secrets, API keys and ceilings itself, on its own routes in front of
  `Wardrik.HTTP`, described by `priv/openapi.json`: `GET`, `PUT` and `DELETE
  /v1/owners/{owner}/secrets/{name}`, and `GET /v1/owners/{owner}/ceilings`. See
  `WardrikDaemon.HTTP`, `WardrikDaemon.Secrets`, `WardrikDaemon.Keys` and `WardrikDaemon.Ceiling`.
  Roles' `kinds` take `secret` and `ceiling`.
- Tokens are the daemon's own, `WardrikDaemon.Tokens`: each a user with groups, or an agent, kept
  as a SHA-256 hash. The `wardrik` command's acts as the deployment's admin, `user:admin`.
- A reload that finds `config.yaml` or `policies/` changed restarts the daemon to read them, so
  `wardrik init` against a running daemon, or in its container, takes effect without a restart.

### Breaking

- `token create`, `token ls` and `token revoke` are gone, with the HTTP API's tokens.
- `reload` and `agent cancel` take agents' IDs, not patterns.
- Agent files are defined by the deployment's admin.
- `vault put` takes `--for`: `api_key`, `client_secret`, `header` or `signing_secret`. `vault ls`
  says each secret's `PURPOSE`.
- Approving past a ceiling needs only what deciding on the agent needs.
- Browser sign-ins don't finish until the daemon pairs them with the `wardrik` command.
- `notify`'s targets go in `notify.targets`.
- `config.yaml` and `wardrik doctor` refuse what Wardrik refused only as it started, as
  `flow: carrier_pigeon` or an MCP `url` with no scheme, and an `org` or `base_url` that isn't a
  string, or `vault.keys` that aren't strings.
- Errors use NimbleOptions' words, as `storage: unknown options [:s3]`. `channels.*.admins` and
  `create`, `mcp.*.cwd`, and `oauth.client` and `redirect` are unknown options.

## 0.1.0-rc.1 (2026-10-30)

- The daemon: Wardrik on the node's disk or in Postgres, the HTTP API, and the channels
  `config.yaml` names.
- `config.yaml`: org, base URL, defaults, models, MCP servers, OAuth providers, channels, notify
  targets, orgs, storage, the vault's keys and where HTTP listens. `${NAME}` reads the environment,
  the env file or the vault.
- Agents from Markdown files in `agents/`, and policies from `policies/`, read again on reload.
  `defaults` apply to every agent.
- `wardrik init`, which sets up the front door: `assistant.md`, an agent that works with the org's
  agents, with a playbook to edit.
- The `wardrik` command over the HTTP API: ask with the answer streamed, agents, approvals,
  triggers, servers, connections, tokens, the vault and the audit.
- `serve`, `start`, `stop`, `logs` and `service install` in the release's script, and
  `wardrik doctor`, which checks what the daemon reads.
- Tools agents may name: `files` over a workspace of their own, `run_lua` in a sealed sandbox,
  `web_search` through Brave, and `deep_research`.
- An installer for Linux, x86_64 or aarch64, checked against `SHA256SUMS`, and an image for
  elsewhere.
