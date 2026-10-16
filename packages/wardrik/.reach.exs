# Architecture policy for `mix reach.check --arch`.
#
# Wardrik puts core and the packages an application embeds together. It calls
# core's public modules listed below, never the internals, which only core
# calls.
[
  layers: [
    wardrik: ["Wardrik", "Wardrik.Migration"]
  ],
  boundaries: [
    public: [
      "Wardrik.Agent",
      "Wardrik.Agent.Snapshot",
      "Wardrik.Agent.Spec",
      "Wardrik.AgentID",
      "Wardrik.AgentID.Prefix",
      "Wardrik.AgentID.Segment",
      "Wardrik.Audit",
      "Wardrik.Call",
      "Wardrik.Call.Ask",
      "Wardrik.Caller",
      "Wardrik.Catalog.Agents",
      "Wardrik.Catalog.Self",
      "Wardrik.Compaction",
      "Wardrik.Connections",
      "Wardrik.Connections.Owner",
      "Wardrik.Core",
      "Wardrik.Credential",
      "Wardrik.Credentials",
      "Wardrik.Credentials.None",
      "Wardrik.Definition",
      "Wardrik.Definition.None",
      "Wardrik.Definitions",
      "Wardrik.Delegation",
      "Wardrik.Error",
      "Wardrik.Event",
      "Wardrik.Event.Bus",
      "Wardrik.Event.Codec.Value",
      "Wardrik.Event.Export",
      "Wardrik.Event.Log",
      "Wardrik.Event.Log.Entry",
      "Wardrik.Fleet",
      "Wardrik.Fleet.Member",
      "Wardrik.Grant",
      "Wardrik.Grants",
      "Wardrik.Hook",
      "Wardrik.Host",
      "Wardrik.LLM.Config",
      "Wardrik.LLM.Cost",
      "Wardrik.LLM.Message",
      "Wardrik.LLM.Usage",
      "Wardrik.Label",
      "Wardrik.Ledger",
      "Wardrik.Ledger.Guarded",
      "Wardrik.Ledger.Key",
      "Wardrik.Ledger.None",
      "Wardrik.Ledger.Store",
      "Wardrik.Principal",
      "Wardrik.Scope",
      "Wardrik.Subagent",
      "Wardrik.Test",
      "Wardrik.Test.*",
      "Wardrik.TimeZone",
      "Wardrik.Tokens",
      "Wardrik.Tool",
      "Wardrik.Tool.Context",
      "Wardrik.Tool.Result",
      "Wardrik.Triggers",
      "Wardrik.UUID",
      "Wardrik.Workspace",
      "Wardrik.Workspace.None"
    ],
    internal: [
      "Wardrik.Agent.State",
      "Wardrik.Agent.State.*",
      "Wardrik.LLM.Turn",
      "Wardrik.LLM.Turn.*",
      "Wardrik.LLM.ToolRunner",
      "Wardrik.LLM.Catalog",
      "Wardrik.Fleet.Supervisor",
      "Wardrik.Event.Source",
      "Wardrik.Trace"
    ],
    internal_callers: [
      {"Wardrik.Agent.State", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Agent.State.*", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.LLM.Turn", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.LLM.Turn.*", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.LLM.ToolRunner", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.LLM.Catalog", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Fleet.Supervisor", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Event.Source", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Trace", ["Wardrik", "Wardrik.*"]}
    ]
  ],
  calls: [
    forbidden: [
      # Wardrik takes its settings as the options it is made with, and reads
      # no application environment, its own or another's.
      {["Wardrik", "Wardrik.Migration"],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Application.put_env",
         "Application.delete_env"
       ]}
    ]
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true,
      ignore: ["Wardrik.Test.*", "Wardrik.OrgGrants"]
    ]
  ]
]
