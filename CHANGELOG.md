# Changelog

## Unreleased

* The Nodes page shows each node's resource use, with trends over the last 5 minutes, and the
  agents that use the most memory. It needs `deployment.runtime`.
* An agent's Now card shows its memory, mailbox, processes and work per second. It needs
  `agent.runtime`.
* A link to the documentation at the bottom of the navigation.

## 0.1.0-rc.1

* The dashboard: agents, agent timelines with approvals, approvals, audit, nodes, and a form for
  every operation.
* Forms built from each operation's schema, with groups, choices and lists in place of raw JSON.
* New agents, an editable definition, a Triggers tab, and Move and Delete.
* Operations that webhooks and chat apps call are set apart.
* A menu that slides in on narrow screens, and tables that stack on phones.
* `WardrikWeb.Resolver`, `WardrikWeb.Extension` and `WardrikWeb.Page`.
