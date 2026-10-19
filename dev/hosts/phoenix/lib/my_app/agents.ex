defmodule MyApp.Agents do
  @moduledoc "Wardrik in this app: where it keeps everything, what runs, and what users do with agents."

  alias Wardrik.AgentID

  def store, do: Wardrik.store(repo: MyApp.Repo)

  def wardrik do
    vault = vault()

    Wardrik.new(
      store: store(),
      issuer: %MyApp.Issuer{},
      credentials: vault,
      connections: %WardrikOAuth.Connections{oauth: oauth(), vault: vault},
      context: Wardrik.context(servers: [github: [orgs: :all]], mcp: WardrikMCP)
    )
  end

  def vault,
    do:
      WardrikVault.new(
        store: store(),
        keys: [System.fetch_env!("WARDRIK_VAULT_KEY")],
        grants: oauth()
      )

  def oauth do
    WardrikOAuth.new(
      client: [name: "My app"],
      providers: [
        github: [
          resource: "https://api.githubcopilot.com/mcp/",
          issuer: "https://github.com/login/oauth",
          client_id: System.get_env("GITHUB_CLIENT_ID"),
          client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
          scopes: ~w(repo)
        ]
      ],
      redirect: [url: System.get_env("MY_APP_URL", "http://localhost:4000") <> "/oauth"]
    )
  end

  def children do
    store = store()
    wardrik = wardrik()

    [
      {WardrikStore, store},
      {Wardrik, wardrik},
      WardrikOAuth.Supervisor,
      {WardrikMCP.Supervisor,
       store: store,
       servers: [
         github: [
           transport: {:streamable_http, base_url: "https://api.githubcopilot.com/mcp/"},
           credential: "github"
         ]
       ]},
      {WardrikHTTP.Access, store: store},
      WardrikHTTP.Workers,
      {WardrikHTTP.Listener,
       host: wardrik,
       port: 4850,
       authenticator: %MyAppWeb.Session{endpoint: MyAppWeb.Endpoint}}
    ]
  end

  def define(user, name, definition) do
    agent = AgentID.new!(name, org: user.org, user: to_string(user.id))
    Wardrik.agent_define(scope(user), agent, definition)
  end

  def ask(user, agent, text), do: Wardrik.agent_ask(scope(user), agent, text)

  def subscribe(user, agent),
    do: Wardrik.subscribe(scope(user), resources: [AgentID.resource(agent)])

  def events(user, agent, cursor),
    do:
      Wardrik.events(scope(user),
        resources: [AgentID.resource(agent)],
        after: cursor,
        follow: true
      )

  def connect(user, provider),
    do: Wardrik.connections_connect(scope(user), MyApp.Issuer.own(user), provider)

  def connections(user), do: Wardrik.connections_list(scope(user), MyApp.Issuer.own(user))

  defp scope(user), do: Wardrik.as(wardrik(), MyApp.Issuer.principal(user))
end
