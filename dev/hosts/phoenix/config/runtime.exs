
# Wardrik in this app: kept in its Repo, its people's tokens sealed with the
# vault's key, signing in to GitHub, offering GitHub's MCP server, answering
# in each org's own Slack workspace, and serving its HTTP API where the
# endpoint mounts it, at /agents.
config :my_app, MyApp.Agents,
  store: [repo: MyApp.Repo],
  vault: [keys: [System.fetch_env!("WARDRIK_VAULT_KEY")]],
  plugins: [
    {WardrikOAuth,
     redirect: [url: System.get_env("MY_APP_URL", "http://localhost:4000") <> "/agents/oauth"],
     client: [name: "My app"],
     providers: [
       github: [
         resource: "https://api.githubcopilot.com/mcp/",
         issuer: "https://github.com/login/oauth",
         client_id: System.get_env("GITHUB_CLIENT_ID"),
         client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
         scopes: ~w(repo)
       ]
     ]},
    {WardrikMCP,
     servers: [github: [url: "https://api.githubcopilot.com/mcp/", credential: "github"]]},
    {WardrikChannel, MyApp.Slack.settings()},
    WardrikHTTP
  ]
