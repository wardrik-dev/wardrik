# Architecture policy for `mix reach.check --arch`.
#
# WardrikBrave depends on core and calls the public modules listed below, never the
# internals, which only core calls.
[
  layers: [
    brave: ["WardrikBrave", "WardrikBrave.*"]
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
      # A package takes its settings as the options it is called with, and
      # reads no application environment, its own or another's; nor does it
      # reach core's store or supervisors by name.
      {["WardrikBrave", "WardrikBrave.*"],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Application.put_env",
         "Application.delete_env",
         "Wardrik.Fleet.Supervisor.store"
       ]}
    ]
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true,
      ignore: ["Wardrik.Test.*", "WardrikBrave.Case"]
    ]
  ]
]
