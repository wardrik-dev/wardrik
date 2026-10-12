# Architecture policy for `mix reach.check --arch`.
#
# The launcher calls the public modules listed below, never the internals.
[
  layers: [
    launcher: ["Mix.Tasks.Wardrik", "Mix.Tasks.Wardrik.*"],
    demo: ["WardrikDemo", "WardrikDemo.*"]
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
      "Wardrik.Audit",
      "Wardrik.Call",
      "Wardrik.Call.Ask",
      "Wardrik.Compaction",
      "Wardrik.Credential",
      "Wardrik.Definition",
      "Wardrik.Delegation",
      "Wardrik.Deployment",
      "Wardrik.DeploymentOperation",
      "Wardrik.Event",
      "Wardrik.Event.Bus",
      "Wardrik.Event.Codec.Value",
      "Wardrik.Event.Export",
      "Wardrik.Event.Log",
      "Wardrik.Event.Log.Entry",
      "Wardrik.Fleet",
      "Wardrik.Fleet.Member",
      "Wardrik.Grant",
      "Wardrik.Hook",
      "Wardrik.Label",
      "Wardrik.Ledger",
      "Wardrik.Ledger.Store",
      "Wardrik.LLM.Config",
      "Wardrik.LLM.Cost",
      "Wardrik.LLM.Message",
      "Wardrik.LLM.Usage",
      "Wardrik.Principal",
      "Wardrik.Scope",
      "Wardrik.Subagent",
      "Wardrik.Test",
      "Wardrik.Test.*",
      "Wardrik.Tool",
      "Wardrik.Tool.Context",
      "Wardrik.Tool.Result",
      "Wardrik.UUID"
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
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true,
      ignore: ["Wardrik.Test.*"]
    ]
  ]
]
