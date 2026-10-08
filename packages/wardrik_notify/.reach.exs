# Architecture policy for `mix reach.check --arch`.
#
# WardrikNotify depends on core and calls the public modules listed below, never the
# internals, which only core calls.
[
  layers: [
    notify: ["WardrikNotify", "WardrikNotify.*"]
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
      "Wardrik.Call",
      "Wardrik.Call.Ask",
      "Wardrik.Compaction",
      "Wardrik.Credential",
      "Wardrik.Delegation",
      "Wardrik.Event",
      "Wardrik.Event.Bus",
      "Wardrik.Event.Codec.Value",
      "Wardrik.Event.Log",
      "Wardrik.Event.Log.Entry",
      "Wardrik.Fleet",
      "Wardrik.Fleet.Member",
      "Wardrik.Grant",
      "Wardrik.Hook",
      "Wardrik.Label",
      "Wardrik.LLM.Config",
      "Wardrik.LLM.Cost",
      "Wardrik.LLM.Message",
      "Wardrik.LLM.Usage",
      "Wardrik.Principal",
      "Wardrik.Scope",
      "Wardrik.Store",
      "Wardrik.Store.Durable",
      "Wardrik.Subagent",
      "Wardrik.Test",
      "Wardrik.Test.*",
      "Wardrik.Tool",
      "Wardrik.Tool.Context",
      "Wardrik.Tool.Result",
      "Wardrik.UUID",
      "Wardrik.Workflow",
      "Wardrik.Workflow.Step"
    ],
    internal: [
      "Wardrik.Agent.State",
      "Wardrik.Agent.State.*",
      "Wardrik.LLM.Turn",
      "Wardrik.LLM.Turn.*",
      "Wardrik.LLM.ToolRunner",
      "Wardrik.LLM.Catalog",
      "Wardrik.Fleet.Supervisor",
      "Wardrik.Ledger.Store",
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
      {"Wardrik.Ledger.Store", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Event.Source", ["Wardrik", "Wardrik.*"]},
      {"Wardrik.Trace", ["Wardrik", "Wardrik.*"]}
    ]
  ],
  calls: [
    forbidden: [
      # A package reads its own settings through one config module, never
      # another package's key, and never core's store or supervisors by name.
      {["WardrikNotify", "WardrikNotify.*"],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Wardrik.Fleet.Supervisor.store"
       ],
       except: ["WardrikNotify.Config"]}
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
