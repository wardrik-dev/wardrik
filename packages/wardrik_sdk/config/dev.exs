import Config

config :logger, level: :debug

# Each package reads its settings from its own application, keyed by the
# module that reads them. See `WardrikBrave.Config`.
config :wardrik_brave, WardrikBrave, api_key: System.get_env("BRAVE_API_KEY")

config :wardrik_mcp, WardrikMCP,
  servers: [
    stub: [
      transport:
        {:stdio,
         command: "elixir",
         args: [Path.expand("../../wardrik_mcp/test/support/mcp/stub_server.exs", __DIR__)]}
    ],
    fs: [
      transport:
        {:stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"]},
      only: ~w(read_file list_directory)
    ],
    linear: [
      transport:
        {:streamable_http,
         base_url: "https://mcp.linear.app/mcp",
         headers: %{"authorization" => "Bearer " <> System.get_env("LINEAR_TOKEN", "")}}
    ],
    github: [
      transport: {:streamable_http, base_url: "https://api.githubcopilot.com/mcp/"},
      credential: {:user, "github"},
      only: ~w(search_issues get_issue)
    ],
    slack: [
      transport: {:streamable_http, base_url: "https://mcp.slack.com/mcp"},
      credential: {:user, "slack"},
      only: ~w(slack_send_message slack_search_channels slack_read_channel)
    ]
  ]

config :wardrik_oauth, WardrikOAuth,
  providers: [
    github: [
      resource: "https://api.githubcopilot.com/mcp/",
      client_id: System.get_env("GITHUB_CLIENT_ID"),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
      scopes: ~w(repo read:org)
    ],
    slack: [
      resource: "https://mcp.slack.com",
      client_id: System.get_env("SLACK_CLIENT_ID"),
      client_secret: System.get_env("SLACK_CLIENT_SECRET"),
      scopes: ~w(channels:read channels:history groups:history chat:write users:read)
    ]
  ]

config :wardrik_vault, WardrikVault, keys: [System.get_env("WARDRIK_VAULT_KEY")]

config :req_llm,
  debug: true,
  receive_timeout: 120_000,
  thinking_timeout: 300_000,
  zai_api_key: System.get_env("ZAI_API_KEY")
