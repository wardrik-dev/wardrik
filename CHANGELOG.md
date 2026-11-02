# Changelog

## 0.1.0-rc.2 (2026-10-31)

- `:resolver`, `Wardrik.Resolver`, required: the host says what each agent gets, as
  `Wardrik.Resolved`: who it acts for, its policies, defaults and middleware, the MCP servers and
  notify targets its definition's names reach, the workspace each channel posts its notices in
  (`:channels`), and the other agents' workspaces it may mount, `:read` or `:write`
  (`:workspaces`). A name it isn't resolved with reaches nothing, whatever is started by that
  name.
- `Wardrik.Channels.owned/2`: a channel's installations an owner holds, for a resolver's
  `:channels`.
- `Wardrik.refresh/2` takes `agents:`, or nothing for every awake agent.
- `Wardrik.Resolved`'s `:notify` takes a target of your app's own as `{module, opts}`, checked
  against its module's `c:Wardrik.Notify.schema/0` by `Wardrik.Notify.given/1`.
- Secrets by reference: an MCP server's header secrets are named, read from the owner's vault as
  each is used, and never answered.
- `Wardrik.schema/0`: `Wardrik.start_link/1`'s options as a NimbleOptions schema, for a host that
  reads them from a file. Each notify target's options are checked as Wardrik starts, by
  `c:Wardrik.Notify.schema/0`.
- `:credentials`, `:key_source` and `:grants`: where every agent's credentials, API keys and OAuth
  grants come from, in place of the vault and `WardrikOAuth`.
- `Wardrik.mcp/1` takes the instance's name or struct, and returns its `WardrikMCP`, for
  `WardrikMCP.add/3`.

### Breaking

- Agent IDs are your app's opaque text, as `agt_01JF8X5RQ2`. Wardrik never parses or names
  them: `Wardrik.AgentID` and the agent's `name` in snapshots and lists are gone.
- A conversation is a field, not an ID suffix. Operations on an agent take an optional
  `conversation`, as `Wardrik.Agent.ask(scope, "agt_1", content: "Hi", conversation: "C1")`, and
  `Wardrik.Agent.stream/4` and `reply/4` take `conversation:`. The authorizer decides a
  conversation as its agent, `{:agent, id}`.
- Events carry `agent` and `conversation`. `Wardrik.cursor/1` takes
  `%{{agent, conversation} => sequence}`. `agents:` filters cover each agent's conversations,
  and listeners follow every agent unless given `:agents`.
- Workers' calls, notices, interrupts and `Wardrik.Delegation.asked/2`'s `:asker` carry the
  conversation too.
- `:oauth` requires `:resolver`, the `WardrikOAuth.Resolver` that says which OAuth app each
  principal signs in with. `:oauth`'s `:providers` is gone.
- OAuth apps and connected accounts are `wardrik_daemon`'s: `providers.*`, `connections.*`,
  `Wardrik.Operations.Providers`, `Wardrik.Operations.Owners` and the `{:owner, owner}` resource
  are gone.
- MCP servers and notify targets that orgs and people add are `wardrik_daemon`'s:
  `mcp_servers.*`, `notify_targets.*`, `Wardrik.Operations.NotifyTargets`, `Wardrik.Notify`'s
  `owned/2`, `targets/2`, `key/1`, `key/2` and `:req_options`, `Wardrik.MCPTools.key/2` and
  `serving/2`, and `:orgs` on `:mcp` servers and `:notify` targets are gone.
- Each seam's callback takes one request struct, then its options: `authorize/2` a
  `Wardrik.Authorizer.Request`, and `resolve/2` a `Wardrik.Resolver.Request`.
- Implements rc.2 of the packages' seams, each taking a request struct:
  `Wardrik.TriggerTarget` (`WardrikTriggers.Target`), and `Wardrik` as
  `Wardrik.Server`. A channel's `request/2` and `notify/2` take the request first.
- A `Wardrik.Authorizer.Request` names the principal, the action and the resource as `{kind, id}`,
  as Cedar's requests do. An agent is `{:agent, id}`, its ID as given, and the deployment
  `{:deployment, name}`.
- No grants or tokens: `:authorizer` is required, and the request names the `actor` as well as
  the principal, as RFC 8693 does. An agent's tools and its answers to other agents act for its
  resolved principal with `actor: {:agent, id}`. `Wardrik.Statements`, `Wardrik.grant/2`,
  `Wardrik.authenticate/2` and the `tokens.*` operations are gone, `Wardrik.as/3` takes
  `:actor` and `:context`, and the operations over many agents take `agents` for `resources`.
- No tenancy: Wardrik reads no owner or org from an ID. `Wardrik.Owners.Resolver` and the
  `:workspace` option are gone; a definition's `workspace.shared` mounts other agents' workspaces
  by `agent` ID, as the resolver shares them, and an agent's own tree is
  `agents/<URL-encoded id>`. Agent tools
  name agents by exact ID, and `agents_list` lists every agent the authorizer lets the agent read.
  `Wardrik.Listener` takes `:agents`, exact IDs, for `:resources`. A worker call's `meta.agent` is
  `%{"key" => id}`. A trigger's signing secret is the resolved principal's. `Wardrik.Notify.Room`
  takes no `:approvers`, and posts in the workspace the agent's resolver gives for the channel,
  or skips the notice.
- A notify target another org's agents use reads as one that isn't there, and `*` and
  `servers/*` reach the servers an agent is resolved with: Wardrik's own that serve its org, and
  those its owners added.
- `finish_sign_in/3` takes `as:`, the principal finishing the sign-in, and `sign_in_pages/2` and
  `Wardrik.HTTP`'s `:principal` say who is at the browser. Without them, no callback finishes.
- `Wardrik.start_link/1` raises `NimbleOptions.ValidationError` on a bad option, not
  `ArgumentError`, and `nil` no longer stands for an unset option.
- Secrets, API keys, ceilings and org settings move to `wardrik_daemon`: the `secrets.*` and
  `ceilings.list` operations, `put_secret/2`, `fetch_secret/2`, `lookup_secret/2`,
  `delete_secret/2` and `list_secrets/1,2`, `Wardrik.Keys` and `:deployment_keys`,
  `Wardrik.Ceiling`, `Wardrik.Orgs`, `Wardrik.OrgSettings`, `:orgs` and `refresh/2`'s `org:` are
  gone. Without `:key_source`, agents get no key source, and approving past a budget needs no
  `ceiling.approve`.
- `Wardrik.Channels.install_url/2`, `installed/2` and `uninstall/2` take the `:channel`, then
  `:owner` and `:query`, or `:workspace`, by name. `Wardrik.Delegation.asked/2` takes `:asker`,
  `:agent` and `:message`, `Wardrik.Workspaces.resolve/2` `:agent`, `:definition` and `:files`,
  and `Wardrik.Operations.Changes`' functions the change's `:type`, `:agent`, `:subject` and
  `:data`. `Wardrik.Runner.run/3` and `stream/3` run and stream an operation, and
  `Wardrik.Answers.follow/4` takes its options last, as `[]` unless given.

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
