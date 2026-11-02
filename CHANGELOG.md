# Changelog

## 0.1.0-rc.2 (2026-10-31)

- `:resolver`, `Wardrik.Resolver`: the host says what each agent gets, as `Wardrik.Resolved`:
  who it acts for, its policies, defaults and middleware, and the MCP servers and notify targets
  its definition's names reach. A name it isn't resolved with reaches nothing, whatever is started
  by that name. Without `:resolver`, `Wardrik.Owners.Resolver` resolves along the owner chain.
- `Wardrik.refresh/2` takes `agents:`, or nothing for every awake agent.
- `:oauth` takes `:resolver`, the `WardrikOAuth.Resolver` that says which OAuth app each
  principal signs in with.
- Settings resolve along the owner chain, `Wardrik.Owners.chain/1`: a person's own, their org's,
  then the deployment's, the nearest of a name winning. Agents get MCP servers, OAuth apps and
  notify targets this way.
- `providers.list`, `providers.add` and `providers.remove`: OAuth apps an org or person keeps for
  their people. `connections.list` offers a person each app they can sign in with.
- An MCP server's `auth.oauth` names an app as `provider`, so connecting the app once covers the
  server. An inline app takes `authorization_params`.
- `notify_targets.list`, `notify_targets.add` and `notify_targets.remove`: webhooks an org or
  person adds for their agents' notices. `notify: "ops"` goes to the nearest `ops` along the
  agent's owner's chain, then to `:notify`'s. A target's URL passes `:egress` as it's added and as
  each notice is sent, with no redirect followed. `:notify` takes `:req_options` for them.
- Secrets by reference: an OAuth app's client secret, an MCP server's header secrets and a notify
  target's secret are named, read from the owner's vault as each is used, and never answered.
  Putting or deleting a secret connects its MCP servers again on every node.
- `mcp_servers.list` answers the servers an owner's agents reach, each with `owner` and `source`,
  and never their headers. `mcp_servers.remove` removes the owner's own.
- `Wardrik.schema/0`: `Wardrik.start_link/1`'s options as a NimbleOptions schema, for a host that
  reads them from a file. Each notify target's options are checked as Wardrik starts, by
  `c:Wardrik.Notify.schema/0`.
- `:credentials`, `:key_source` and `:grants`: where every agent's credentials, API keys and OAuth
  grants come from, in place of the vault, `Wardrik.Keys` and `WardrikOAuth`.
- An error from a server's own sign-in names the server.

### Breaking

- A notify target another org's agents use reads as one that isn't there, and `*` and
  `servers/*` reach the servers an agent is resolved with: Wardrik's own that serve its org, and
  those its owners added.
- `finish_sign_in/3` takes `as:`, the principal finishing the sign-in, and `sign_in_pages/2` and
  `Wardrik.HTTP`'s `:principal` say who is at the browser. Without them, no callback finishes.
- `secrets.put` takes a `purpose`: `api_key`, `client_secret`, `header` or `signing_secret`. Each
  secret is read only for its purpose, so an API key is only ever an `api_key`, and
  `deployment_keys` gives no client secret, header or signing secret as a key.
- `Wardrik.start_link/1` raises `NimbleOptions.ValidationError` on a bad option, not
  `ArgumentError`, and `nil` no longer stands for an unset option.
- An agent falls back to the deployment's API keys only with `deployment_keys: true`. A person's
  agent still falls back to their org's.
- `Wardrik.Keys` takes `vault:` and `deployment:` options, and `Wardrik.Keys.owners/2`
  whether the deployment's keys count.
- OAuth apps added at runtime for MCP servers' sign-ins are kept under new keys. Add those servers
  again.

## 0.1.0-rc.1 (2026-10-30)

- `use Wardrik`: one module in your supervision tree that runs agents, keeps them in a
  `WardrikStore`, and holds them to a deployment-wide policy.
- Agents defined as data: model, instructions, tools, policy and triggers. Ask them, stream their
  answers, or wait for a `Wardrik.Reply`.
- Policies held at once by the deployment and each agent: rules that allow, ask or deny, budgets
  per agent, and ceilings per org.
- Approvals, for the people you choose to decide the calls agents wait on.
- Scopes that act as a person, with grants, roles, API tokens and your own authorizer.
- MCP servers Wardrik starts with, and servers an org or person adds as it runs. Credentials sealed
  at rest, and sign-ins that give agents people's accounts.
- Every operation as a function that takes and answers structs. Events and an audit to follow into
  your app.
- Guides for each, and Livebook notebooks that show them in action.
