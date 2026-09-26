# Architecture policy for `mix reach.check --arch`.
#
# Core is `Wardrik.*`. Every other namespace is a package that will one day be its
# own Mix project depending on `:wardrik`, so a package may call core and nothing
# else, and core may call no package.
[
  layers: [
    core: ["Wardrik", "Wardrik.*"],
    brave: ["WardrikBrave", "WardrikBrave.*"],
    research: ["WardrikResearch", "WardrikResearch.*"],
    lua: ["WardrikLua", "WardrikLua.*"],
    mcp: ["WardrikMCP", "WardrikMCP.*"],
    oauth: ["WardrikOAuth", "WardrikOAuth.*"],
    vault: ["WardrikVault", "WardrikVault.*"],
    tui: ["WardrikTUI", "WardrikTUI.*"],
    daemon: ["WardrikDaemon", "WardrikDaemon.*"],
    policy: ["WardrikPolicy", "WardrikPolicy.*"],
    notify: ["WardrikNotify", "WardrikNotify.*"],
    http: ["WardrikHTTP", "WardrikHTTP.*"],
    s3: ["WardrikS3", "WardrikS3.*"],
    ecto: ["WardrikEcto", "WardrikEcto.*"],
    console: "WardrikConsole",
    launcher: "Mix.Tasks.Wardrik",
    demo: ["WardrikDemo", "WardrikDemo.*"]
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
      daemon: [
        :core,
        :mcp,
        :oauth,
        :vault,
        :brave,
        :research,
        :lua,
        :policy,
        :tui,
        :notify,
        :http
      ],
      policy: [:core],
      notify: [:core],
      http: [:core],
      s3: [:core],
      ecto: [:core],
      console: [:core],
      demo: [:core],
      launcher: [:core, :tui, :mcp, :oauth, :vault, :brave, :research]
    ]
  ],
  boundaries: [
    internal: [
      "Wardrik.Agent.State",
      "Wardrik.Agent.State.*",
      "Wardrik.LLM.Turn",
      "Wardrik.LLM.Turn.*",
      "Wardrik.LLM.ToolRunner",
      "Wardrik.LLM.Catalog",
      "Wardrik.Sandbox.Runner",
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
      {"Wardrik.Sandbox.Runner", ["Wardrik", "Wardrik.*"]},
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
      {[
         "WardrikBrave",
         "WardrikBrave.*",
         "WardrikResearch",
         "WardrikResearch.*",
         "WardrikLua",
         "WardrikLua.*",
         "WardrikMCP",
         "WardrikMCP.*",
         "WardrikOAuth",
         "WardrikOAuth.*",
         "WardrikVault",
         "WardrikVault.*",
         "WardrikTUI",
         "WardrikTUI.*",
         "WardrikNotify",
         "WardrikNotify.*",
         "WardrikHTTP",
         "WardrikHTTP.*",
         "WardrikS3",
         "WardrikS3.*",
         "WardrikEcto",
         "WardrikEcto.*"
       ],
       [
         "Application.get_env",
         "Application.fetch_env",
         "Application.fetch_env!",
         "Wardrik.Fleet.Supervisor.store"
       ],
       except: [
         "WardrikBrave.Config",
         "WardrikMCP.Config",
         "WardrikOAuth.Config",
         "WardrikVault.Config",
         "WardrikNotify.Config",
         "WardrikHTTP.Config"
       ]}
    ]
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true,
      ignore: ["Wardrik.Test.*", "WardrikBrave.Case", "WardrikOAuth.Case"]
    ]
  ]
]
