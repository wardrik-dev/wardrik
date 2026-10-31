# Changelog

## Unreleased

- `providers.list`, `providers.add` and `providers.remove`: OAuth apps an org or person adds for
  their people. A person signs in with the nearest of a name: their own, their org's, then the
  deployment's. An app's client secret is named by reference, and never answered.
- `connections.list` offers a person their own, their org's and the deployment's apps.
- An MCP server's `auth.oauth` can name an app as `provider`, so connecting the app once covers
  the server. An inline app takes `authorization_params`.
- An inline app's client secret is read from the owner's vault each time it's needed, so a new
  value takes effect without adding the server again.
- OAuth apps added at runtime in rc.1, for servers' sign-ins, are kept under new keys. Add those
  servers again.
- `mcp_servers.list` answers the servers the owner's agents reach: their own, then those from
  further out, including those Wardrik started with, each with `owner` and `source`. Never
  headers. `mcp_servers.remove` removes the owner's own alone.
- An MCP server's secrets are named in its headers and read as each connection starts, an owner's
  server reading that owner's alone. Putting or deleting a secret connects its servers again on
  every node, so a new value takes effect without adding the server again or restarting.
- An error from a server's own sign-in names the server.

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
