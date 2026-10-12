# Architecture policy for `mix reach.check --arch`.
#
# WardrikHTTP depends on core and calls the public modules listed below, never the
# internals, which only core calls.
[
  layers: [
    http: ["WardrikHTTP", "WardrikHTTP.*"]
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
      "Wardrik.Change",
      "Wardrik.Command",
      "Wardrik.Compaction",
      "Wardrik.Connections",
      "Wardrik.Credential",
      "Wardrik.Definition",
      "Wardrik.Delegation",
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
      "Wardrik.Hook",
      "Wardrik.Label",
      "Wardrik.Ledger",
      "Wardrik.Ledger.Store",
      "Wardrik.LLM.Config",
      "Wardrik.LLM.Cost",
      "Wardrik.LLM.Message",
      "Wardrik.LLM.Usage",
      "Wardrik.Operations.*",
      "Wardrik.Principal",
      "Wardrik.Query",
      "Wardrik.Resource",
      "Wardrik.Scope",
      "Wardrik.Subagent",
      "Wardrik.Subject",
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
  calls: [
    forbidden: [
      # A package takes its settings as the options its host starts it with,
      # and reads no application environment, its own or another's; nor
      # core's store or supervisors by name.
      {["WardrikHTTP", "WardrikHTTP.*"],
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
      ignore: ["Wardrik.Test.*"]
    ]
  ]
]
