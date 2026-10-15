defmodule MyApp.Agents do
  @moduledoc "Wardrik in this app: where it keeps everything, what runs, and what users do with agents."

  alias Wardrik.AgentID
  alias Wardrik.Operations.Ask
  alias Wardrik.Operations.Connect
  alias Wardrik.Operations.Define
  alias Wardrik.Operations.ReadConnections

  def store, do: WardrikStore.new(adapter: WardrikEcto.Store, repo: MyApp.Repo)

  def host do
    store = store()
    vault = vault()

    Wardrik.Host.new(
      store: store,
      grants: %MyApp.Grants{},
      definitions: %WardrikDefinition.Kept{store: store, contexts: context()},
      credentials: vault,
      connections: %WardrikOAuth.Connections{oauth: oauth(), vault: vault}
    )
  end

  def context, do: %WardrikDefinition.Context{servers: [github: [orgs: :all]], mcp: WardrikMCP}

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
    host = host()

    [
      {WardrikStore, store},
      {Wardrik, host: host},
      {WardrikPolicy.Supervisor, store: store},
      {WardrikTrigger, store: store},
      {WardrikOAuth.Supervisor, oauth: oauth(), callback: false},
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
       host: host, port: 4850, authenticator: %MyAppWeb.Session{endpoint: MyAppWeb.Endpoint}}
    ]
  end

  def define(user, name, definition) do
    agent = AgentID.new!(name, org: user.org, user: to_string(user.id))

    with {:ok, caller} <- caller(user, agent),
         do: Wardrik.Command.run(%Define{agent: agent, definition: definition}, caller)
  end

  def ask(user, agent, text) do
    with {:ok, caller} <- caller(user, agent),
         {:ok, request} <- Ask.new(agent, %{"content" => text}),
         do: Wardrik.Command.run(request, caller)
  end

  def connect(user, provider) do
    owner = MyApp.Grants.own(user)

    with {:ok, caller} <- caller(user, owner),
         do: Wardrik.Command.run(%Connect{owner: owner, provider: provider}, caller)
  end

  def connections(user) do
    owner = MyApp.Grants.own(user)

    with {:ok, caller} <- caller(user, owner),
         do: Wardrik.Query.run(%ReadConnections{owner: owner}, caller)
  end

  defp caller(user, subject),
    do: Wardrik.Host.caller(host(), principal: MyApp.Grants.principal(user), subject: subject)
end
