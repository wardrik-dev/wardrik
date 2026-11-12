# Changelog

## Unreleased

- Agents whose saved state can't be read show as `unreadable`, with the reason on the agent's
  page.

## 0.1.0-rc.1 (2026-11-11)

The first release: a LiveView dashboard for Wardrik that you mount in your Phoenix router.

* Pages for agents, agent timelines with approvals, approvals, the audit, nodes, and a form for
  every operation. The pages update while agents run.
* Forms built from each operation's schema, with groups, choices and lists in place of raw JSON.
  Fields marked `"writeOnly": true` are password fields.
* New agents, an editable definition, a Triggers tab, an Access tab, and Move and Delete. The
  Access tab shows what your app gives the agent. It needs `agent.resolved`.
* The Nodes page shows each node's resource use, with trends over the last 5 minutes and a
  tooltip on each figure, what runs on each node, the agents that use the most memory, and how
  many agents are working, idle, waiting on a person and asleep. It needs `deployment.runtime`.
* An agent's Now card shows its memory, mailbox, processes and work per second. It needs
  `agent.runtime`.
* Settings pages for MCP servers, secrets, notify targets, OAuth apps and connections. Turn each
  on with the router's `:settings` option and a `WardrikWeb.Settings` or
  `WardrikWeb.Connections` module. A page that's off says how to turn it on.
* `WardrikWeb.Resolver`, `WardrikWeb.Extension`, `use WardrikWeb.Page` for extension pages, and
  `owner_picker/1` in `WardrikWeb.Components`.
* Operations that webhooks and chat apps call are set apart.
* A menu that slides in on narrow screens, tables that stack on phones, and sections that stay
  open or closed when the page refreshes.
