# Architecture policy for `mix reach.check --arch`.
#
# WardrikOAuth depends on core and calls the public modules listed below, never the
# internals, which only core calls.
[
  layers: [
    oauth: ["WardrikOAuth", "WardrikOAuth.*", "WardrikVault.Grants.WardrikOAuth", "Wardrik.Connections.WardrikOAuth.Connections"]
  ],
  boundaries: [
    public: [
      "Wardrik.Core",
      "Wardrik.Agent",
      "Wardrik.Agent.Activity",
      "Wardrik.Agent.Activity.English",
      "Wardrik.Agent.Activity.Presenter",
      "Wardrik.Agent.Snapshot",
      "Wardrik.Agent.Spec",
      "Wardrik.AgentID",
      "Wardrik.AgentID.Segment",
      "Wardrik.Audit",
      "Wardrik.Call",
      "Wardrik.Call.Ask",
      "Wardrik.Call.Pipeline",
      "Wardrik.Compaction",
      "Wardrik.Connections",
      "Wardrik.Connections.Connection",
      "Wardrik.Conversation",
      "Wardrik.Conversation.*",
      "Wardrik.Credential",
      "Wardrik.Credentials",
      "Wardrik.Credentials.None",
      "Wardrik.Definition",
      "Wardrik.Definitions",
      "Wardrik.Event",
      "Wardrik.Event.Bus",
      "Wardrik.Event.Codec.Value",
      "Wardrik.Event.Cursor",
      "Wardrik.Event.Log.Entry",
      "Wardrik.Fleet",
      "Wardrik.Fleet.Member",
      "Wardrik.Issuer",
      "Wardrik.Issuer.None",
      "Wardrik.Hook",
      "Wardrik.Host",
      "Wardrik.LLM.Answer",
      "Wardrik.LLM.Client",
      "Wardrik.LLM.Config",
      "Wardrik.LLM.Cost",
      "Wardrik.LLM.Error",
      "Wardrik.LLM.Retry",
      "Wardrik.LLM.Retry.Backoff",
      "Wardrik.LLM.Tools",
      "Wardrik.LLM.Usage",
      "Wardrik.Label",
      "Wardrik.Ledger",
      "Wardrik.Ledger.Key",
      "Wardrik.Principal",
      "Wardrik.Resource",
      "Wardrik.Role",
      "Wardrik.Run",
      "Wardrik.Statement",
      "Wardrik.Subagent",
      "Wardrik.Test",
      "Wardrik.Test.*",
      "Wardrik.TimeZone",
      "Wardrik.Token",
      "Wardrik.Tokens",
      "Wardrik.Tokens.Entry",
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
      # A package takes its settings as options of what the host starts, and
      # reads no application environment, its own or another package's, nor
      # core's store or supervisors by name.
      {["WardrikOAuth", "WardrikOAuth.*"],
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
