# Architecture policy for `mix reach.check --arch`.
#
# Core is `Tars.*`. Every other namespace is a package that will one day be its
# own Mix project depending on `:tars`, so a package may call core and nothing
# else, and core may call no package.
[
  layers: [
    core: ["Tars", "Tars.*"],
    brave: ["TarsBrave", "TarsBrave.*"],
    research: ["TarsResearch", "TarsResearch.*"],
    lua: ["TarsLua", "TarsLua.*"],
    mcp: ["TarsMCP", "TarsMCP.*"],
    oauth: ["TarsOAuth", "TarsOAuth.*"],
    vault: ["TarsVault", "TarsVault.*"],
    tui: ["TarsTUI", "TarsTUI.*"],
    daemon: ["TarsDaemon", "TarsDaemon.*"],
    policy: ["TarsPolicy", "TarsPolicy.*"],
    notify: ["TarsNotify", "TarsNotify.*"],
    console: "TarsConsole",
    launcher: "Mix.Tasks.Tars",
    demo: ["TarsDemo", "TarsDemo.*"]
  ],
  deps: [
    mode: :allowlist,
    allowed: [
      core: [],
      brave: [:core],
      research: [:core],
      lua: [:core],
      mcp: [:core],
      vault: [:core],
      oauth: [:core, :vault],
      tui: [:core],
      daemon: [:core, :mcp, :oauth, :vault, :brave, :research, :lua, :policy, :tui, :notify],
      policy: [:core],
      notify: [:core],
      console: [:core],
      demo: [:core],
      launcher: [:core, :tui, :mcp, :oauth, :vault, :brave, :research]
    ]
  ],
  boundaries: [
    internal: [
      "Tars.Agent.State",
      "Tars.Agent.State.*",
      "Tars.LLM.Turn",
      "Tars.LLM.Turn.*",
      "Tars.LLM.ToolRunner",
      "Tars.LLM.Catalog",
      "Tars.Sandbox.Runner",
      "Tars.Fleet.Supervisor",
      "Tars.Ledger.Store",
      "Tars.Event.Source",
      "Tars.Trace"
    ],
    internal_callers: [
      {"Tars.Agent.State", ["Tars", "Tars.*"]},
      {"Tars.Agent.State.*", ["Tars", "Tars.*"]},
      {"Tars.LLM.Turn", ["Tars", "Tars.*"]},
      {"Tars.LLM.Turn.*", ["Tars", "Tars.*"]},
      {"Tars.LLM.ToolRunner", ["Tars", "Tars.*"]},
      {"Tars.LLM.Catalog", ["Tars", "Tars.*"]},
      {"Tars.Sandbox.Runner", ["Tars", "Tars.*"]},
      {"Tars.Fleet.Supervisor", ["Tars", "Tars.*"]},
      {"Tars.Ledger.Store", ["Tars", "Tars.*"]},
      {"Tars.Event.Source", ["Tars", "Tars.*"]},
      {"Tars.Trace", ["Tars", "Tars.*"]}
    ]
  ],
  calls: [
    forbidden: [
      # A package reads its own settings through one config module, never
      # another package's key, and never core's store or supervisors by name.
      {[
         "TarsBrave",
         "TarsBrave.*",
         "TarsResearch",
         "TarsResearch.*",
         "TarsLua",
         "TarsLua.*",
         "TarsMCP",
         "TarsMCP.*",
         "TarsOAuth",
         "TarsOAuth.*",
         "TarsVault",
         "TarsVault.*",
         "TarsTUI",
         "TarsTUI.*",
         "TarsNotify",
         "TarsNotify.*"
       ],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Tars.Fleet.Supervisor.store"
       ], except: ["TarsBrave.Config", "TarsMCP.Config", "TarsOAuth.Config", "TarsVault.Config", "TarsNotify.Config"]}
    ]
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true,
      ignore: ["Tars.Test.*", "TarsBrave.Case", "TarsOAuth.Case"]
    ]
  ]
]
