import Config

config :logger, level: :debug

# Tool packages under lib/ are not yet their own applications, so their
# settings nest under :tars. See `TarsBrave.Config`.
config :tars, TarsBrave, api_key: System.get_env("BRAVE_API_KEY")

config :tars, TarsMCP,
  servers: [
    stub: [
      transport:
        {:stdio, command: "elixir", args: [Path.expand("test/support/mcp/stub_server.exs")]}
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

config :tars, TarsOAuth,
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
      scopes: ~w(channels:read chat:write users:read)
    ]
  ]

config :tars, TarsVault, keys: [System.get_env("TARS_VAULT_KEY")]

config :req_llm,
  debug: true,
  receive_timeout: 120_000,
  thinking_timeout: 300_000,
  zai_api_key: System.get_env("ZAI_API_KEY")
