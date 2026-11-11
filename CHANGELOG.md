# Changelog

## Unreleased

* The Nodes page explains each figure in a tooltip, shows the memory the OS reports next to the
  BEAM's, adds Persistent terms and Other to memory by type, and lists what runs on each node:
  processes grouped by application and module.
* The Nodes page counts working, idle, waiting and sleeping agents. It needs a server whose
  `deployment.nodes` returns those counts.
* A section you open or close stays that way when the page refreshes.
* The Nodes page shows each node's resource use, with trends over the last 5 minutes, and the
  agents that use the most memory. It needs `deployment.runtime`.
* An agent's Now card shows its memory, mailbox, processes and work per second. It needs
  `agent.runtime`.
* A link to the documentation at the bottom of the navigation.
* Settings pages for MCP servers, secrets, notify targets, OAuth apps and connections. Turn each
  on with the router's `:settings` option and a `WardrikWeb.Settings` or
  `WardrikWeb.Connections` module. A page that's off says how to turn it on.
* An agent's Access tab shows what your app gives it: who it works for, its policies, MCP
  servers and their tools, notify targets, channels and workspaces. It needs `agent.resolved`.
* `use WardrikWeb.Page` for extension pages, and `owner_picker/1` in `WardrikWeb.Components`.
* Form fields marked `"writeOnly": true` are password fields.

## 0.1.0-rc.1

* The dashboard: agents, agent timelines with approvals, approvals, audit, nodes, and a form for
  every operation.
* Forms built from each operation's schema, with groups, choices and lists in place of raw JSON.
* New agents, an editable definition, a Triggers tab, and Move and Delete.
* Operations that webhooks and chat apps call are set apart.
* A menu that slides in on narrow screens, and tables that stack on phones.
* `WardrikWeb.Resolver`, `WardrikWeb.Extension` and `WardrikWeb.Page`.
