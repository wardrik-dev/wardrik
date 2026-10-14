# Architecture policy for `mix reach.check --arch`.
#
# WardrikDaemon depends on core and calls the public modules listed below, never the
# internals, which only core calls.
[
  layers: [
    daemon: ["WardrikDaemon", "WardrikDaemon.*", "Wardrik.Definition.WardrikDaemon.Agents", "Wardrik.Grants.WardrikDaemon.Grants"],
    docs: "Mix.Tasks.Wardrik.Docs"
  ],
  boundaries: [
    public: [
      "Wardrik",
      "Wardrik.Agent",
      "Wardrik.Agent.Snapshot",
      "Wardrik.Agent.Spec",
      "Wardrik.AgentID",
      "Wardrik.AgentID.Prefix",
      "Wardrik.AgentID.Segment",
      "Wardrik.AgentOperation",
      "Wardrik.Audit",
      "Wardrik.Call",
      "Wardrik.Call.Ask",
      "Wardrik.Caller",
      "Wardrik.Catalog.Agents",
      "Wardrik.Catalog.Self",
      "Wardrik.Change",
      "Wardrik.Command",
      "Wardrik.Compaction",
      "Wardrik.Connections",
      "Wardrik.Connections.Owner",
      "Wardrik.Credential",
      "Wardrik.Credentials",
      "Wardrik.Credentials.None",
      "Wardrik.Definition",
      "Wardrik.Definition.None",
      "Wardrik.Definitions",
      "Wardrik.Delegation",
      "Wardrik.Deployment",
      "Wardrik.DeploymentOperation",
      "Wardrik.Effect",
      "Wardrik.Error",
      "Wardrik.Event",
      "Wardrik.Event.Bus",
      "Wardrik.Event.Codec.Value",
      "Wardrik.Event.Export",
      "Wardrik.Event.Log",
      "Wardrik.Event.Log.Entry",
      "Wardrik.Fleet",
      "Wardrik.Fleet.Member",
      "Wardrik.FleetOperation",
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
      "Wardrik.Operations.*",
      "Wardrik.Principal",
      "Wardrik.Query",
      "Wardrik.Resource",
      "Wardrik.Scope",
      "Wardrik.Subagent",
      "Wardrik.Subject",
      "Wardrik.Test",
      "Wardrik.Test.*",
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
  smells: [
    behaviour_candidate: [
      # WardrikDaemon.Approvers is a protocol, and its implementations are the
      # modules the check finds; it groups modules by their public functions,
      # and does not read the protocol they implement.
      ignore: [modules: ["WardrikDaemon.Approvers", "WardrikDaemon.Approvers.*"]]
    ]
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true,
      ignore: ["Wardrik.Test.*"]
    ]
  ]
]
