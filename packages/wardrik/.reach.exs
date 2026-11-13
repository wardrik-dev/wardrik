# Wardrik is one package of subsystems: store, event_log, policy, vault, oauth, mcp, triggers,
# workspace, http, chat and testing. Each calls only the subsystems it builds on, listed in
# `allowed`. The rest of Wardrik (app) wires them together, and may call any. Tests' helpers
# (support) may call anything.
#
# A module is in the first layer that matches it, so the modules that connect a subsystem to the
# rest of Wardrik are named in app ahead of the subsystems.
allowed = [
  store: [],
  event_log: [:store],
  policy: [],
  vault: [:store],
  oauth: [:vault, :store],
  mcp: [:store],
  triggers: [:store],
  workspace: [:store],
  http: [],
  chat: [:event_log, :vault, :store],
  testing: [:event_log, :store]
]

layers = Keyword.keys(allowed) ++ [:app, :support]

[
  layers: [
    app: [
      "Wardrik",
      "Wardrik.Workspace.Agents",
      "Wardrik.Triggers.Agents",
      "Wardrik.Vault.Lookup",
      "Wardrik.OAuth.Apps",
      "Wardrik.Owned",
      "Wardrik.MCP.Capability",
      "Wardrik.AgentTools",
      "Wardrik.AgentTools.*",
      "Wardrik.Answers",
      "Wardrik.Answers.*",
      "Wardrik.Authorizer",
      "Wardrik.Authorizer.*",
      "Wardrik.Catalog",
      "Wardrik.Catalog.*",
      "Wardrik.Channels",
      "Wardrik.Channels.*",
      "Wardrik.Children",
      "Wardrik.Children.*",
      "Wardrik.Compaction",
      "Wardrik.Compaction.*",
      "Wardrik.Declarations",
      "Wardrik.Declarations.*",
      "Wardrik.Definitions",
      "Wardrik.Definitions.*",
      "Wardrik.Delegation",
      "Wardrik.Delegation.*",
      "Wardrik.Digest",
      "Wardrik.Digest.*",
      "Wardrik.Egress",
      "Wardrik.Egress.*",
      "Wardrik.Instance",
      "Wardrik.Instance.*",
      "Wardrik.JSON",
      "Wardrik.JSON.*",
      "Wardrik.Listener",
      "Wardrik.Listener.*",
      "Wardrik.Notify",
      "Wardrik.Notify.*",
      "Wardrik.Operations",
      "Wardrik.Operations.*",
      "Wardrik.OperationTools",
      "Wardrik.OperationTools.*",
      "Wardrik.Resolution",
      "Wardrik.Resolution.*",
      "Wardrik.Resolved",
      "Wardrik.Resolved.*",
      "Wardrik.Resolver",
      "Wardrik.Resolver.*",
      "Wardrik.Runner",
      "Wardrik.Runner.*",
      "Wardrik.Setup",
      "Wardrik.Setup.*",
      "Wardrik.SignIns",
      "Wardrik.SignIns.*",
      "Wardrik.Sleeper",
      "Wardrik.Sleeper.*",
      "Wardrik.Spending",
      "Wardrik.Spending.*",
      "Wardrik.Views",
      "Wardrik.Views.*",
      "Wardrik.Workers",
      "Wardrik.Workers.*"
    ],
    support: [
      "Wardrik.Test",
      "Wardrik.Test.*",
      "Wardrik.*.Test",
      "Wardrik.*.Test.*",
      "Wardrik.MCP.HTTPStub",
      "Wardrik.OAuth.GitHub",
      "Wardrik.OAuth.TestHook",
      "Wardrik.Store.Conformance",
      "Wardrik.Store.Counter",
      "Wardrik.Store.DurableConformance",
      "Wardrik.Store.TestRepo",
      "Wardrik.Store.TestMigration",
      "Wardrik.Vault.TestGrants"
    ],
    store: ["Wardrik.Store", "Wardrik.Store.*"],
    event_log: ["Wardrik.EventLog", "Wardrik.EventLog.*", "Wardrik.Sink"],
    policy: ["Wardrik.Policy", "Wardrik.Policy.*"],
    vault: ["Wardrik.Vault", "Wardrik.Vault.*"],
    oauth: ["Wardrik.OAuth", "Wardrik.OAuth.*"],
    mcp: ["Wardrik.MCP", "Wardrik.MCP.*"],
    triggers: ["Wardrik.Triggers", "Wardrik.Triggers.*"],
    workspace: ["Wardrik.Workspace", "Wardrik.Workspace.*"],
    http: ["Wardrik.HTTP", "Wardrik.HTTP.*"],
    chat: ["Wardrik.Chat", "Wardrik.Chat.*"],
    testing: ["Wardrik.Testing", "Wardrik.Testing.*"]
  ],
  deps: [
    forbidden:
      for({from, may} <- allowed, to <- layers, to != from and to not in may, do: {from, to}) ++
        [{:app, :support}]
  ],
  calls: [
    forbidden: [
      {["Wardrik", "Wardrik.*"],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Application.put_env",
         "Application.delete_env"
       ]}
    ]
  ],
  smells: [
    ignore: [modules: ["Wardrik.Operations.Functions"]]
  ],
  checks: [
    layer_coverage: [require_all_modules: true]
  ]
]
