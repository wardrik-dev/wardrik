defmodule WardrikDaemon.ConfigTest do
  use ExUnit.Case, async: true

  import WardrikDaemon.Test

  alias WardrikDaemon.Config
  alias WardrikDaemon.Dirs

  setup context, do: dirs(context)

  defp read(context, text, env \\ %{}) do
    write(context, "config.yaml", text)
    Config.read(Dirs.new(context.env), Map.merge(context.env, env))
  end

  test "reads as the defaults where there's no config.yaml", %{env: env} do
    assert {:ok, %Config{org: "default", port: 4747, ip: {127, 0, 0, 1}, mcp: [], channels: []}} =
             Config.read(Dirs.new(env), env)
  end

  test "reads what agents reach, with ${NAME} from the environment", context do
    yaml = """
    org: acme
    base_url: https://agents.acme.test/
    defaults: {model: anthropic:claude-haiku-4-5}
    http: {port: 4000, ip: 0.0.0.0}
    vault: {keys: ["${KEY}"]}
    mcp:
      github:
        url: https://api.githubcopilot.com/mcp/
        credential: github
        only: [list_commits]
        timeout: 30
      notes:
        command: npx
        args: [-y, notes]
    oauth:
      providers:
        github: {issuer: https://github.com/login/oauth, client_id: "${GITHUB_CLIENT_ID}", scopes: [repo], flow: device}
    channels:
      slack: {type: slack, token: xoxb-1, app_token: xapp-1, members: {U1: user:acme/@maria}}
      ops: {type: slack, signing_secret: s, client_id: "1.2", client_secret: c, unmapped_members: allow}
    brave: {api_key: "${KEY}"}
    models:
      prices:
        zai_coding_plan:glm-5.1: {priced_as: zai:glm-5.1, markup: 0.1}
        openrouter:x: {input: 0.6, output: 2.2}
      options: {temperature: 0.2, reasoning_effort: low, base_url: "https://llm.acme.test"}
      pool: {size: 128, protocols: [http2]}
    cluster: {}
    """

    assert {:ok, config} = read(context, yaml, %{"KEY" => "k3y", "GITHUB_CLIENT_ID" => "Iv1"})

    assert %Config{org: "acme", port: 4000, keys: ["k3y"], defaults: %{"model" => _model}} =
             config

    assert Config.url(config) == "http://127.0.0.1:4000"
    assert Config.base_url(config) == "https://agents.acme.test"

    assert [
             {"github",
              [
                transport:
                  {:streamable_http, url: "https://api.githubcopilot.com/mcp/", headers: %{}}
              ] ++ github},
             {"notes", [transport: {:stdio, command: "npx", args: ["-y", "notes"], env: %{}}]}
           ] = config.mcp

    assert github == [credential_name: "github", only: ["list_commits"], timeout: 30_000]
    assert [{"github", provider}] = config.oauth[:providers]
    assert provider[:flow] == :device
    assert provider[:client_id] == "Iv1"

    assert [{"ops", {WardrikSlack, ops}}, {"slack", {WardrikSlack, slack}}] =
             Enum.sort(config.channels)

    assert slack == [
             owner: "acme",
             identities:
               {WardrikDaemon.ChannelMembers,
                members: %{"U1" => "acme/@maria"}, unmapped: :refuse},
             req_options: [],
             app_token: "xapp-1",
             token: "xoxb-1"
           ]

    assert ops[:installations] == :stored
    assert {WardrikDaemon.ChannelMembers, members: %{}, unmapped: :allow} = ops[:identities]
    assert config.brave == "k3y"

    assert config.prices == %{
             "zai_coding_plan:glm-5.1" => [markup: 0.1, priced_as: "zai:glm-5.1"],
             "openrouter:x" => [input: 0.6, output: 2.2]
           }

    assert Enum.sort(config.model_options) == [
             base_url: "https://llm.acme.test",
             reasoning_effort: :low,
             temperature: 0.2
           ]

    assert Enum.sort(config.pool) == [count: 1, protocols: [:http2], size: 128]
    assert config.warnings == ["cluster isn't supported here yet, so it's passed over"]
    assert config.deployment_keys
    assert config.oauth[:page] == "https://agents.acme.test/oauth"
  end

  test "reads where everything is kept, from the environment alone", context do
    write(context, "config.yaml", "storage: {postgres: {url: \"${DATABASE}\"}}\n")
    env = Map.put(context.env, "DATABASE", "postgres://u:p@db/wardrik")
    dirs = Dirs.new(env)

    assert {:ok, %{storage: {:postgres, "postgres://u:p@db/wardrik"}}} =
             Config.bootstrap(dirs, env)

    assert {:ok, %Config{storage: {:postgres, _url}}} = Config.read(dirs, env)

    assert {:ok, %Config{storage: nil}} = read(context, "org: acme\n")
    assert {:error, why} = read(context, "storage: {s3: {bucket: b}}\n")
    assert why =~ "storage: unknown options [:s3], valid options are: [:postgres]"
    assert {:error, why} = read(context, "storage: {postgres: {url: mysql://x}}\n")
    assert why =~ "storage.postgres: invalid value for :url option: is a postgres:// URL"
  end

  test "listens where WARDRIK_HTTP_IP says, unless config.yaml says", context do
    env = Map.put(context.env, "WARDRIK_HTTP_IP", "0.0.0.0")
    dirs = Dirs.new(env)

    assert {:ok, %{ip: {0, 0, 0, 0}, port: 4747}} = Config.bootstrap(dirs, env)
    assert {:ok, %Config{ip: {0, 0, 0, 0}}} = Config.read(dirs, env)

    assert {:ok, %Config{ip: {0, 0, 0, 0}, port: 4000}} =
             read(context, "http: {port: 4000}\n", env)

    assert {:ok, %Config{ip: {10, 0, 0, 1}}} =
             read(context, "http: {ip: 10.0.0.1}\n", env)
  end

  test "reads notify's targets", context do
    yaml = """
    org: acme
    channels:
      slack: {type: slack, token: xoxb-1, app_token: xapp-1}
    notify:
      retries: {attempts: 5, max_wait: 20000}
      targets:
        ops: {channel: slack, room: "#ops"}
        audit:
          webhook:
            url: https://hooks.example.com/wardrik
            secret: "${SECRET}"
            req_options: {retry: false}
    """

    assert {:ok, config} = read(context, yaml, %{"SECRET" => "shh"})

    assert Enum.sort(config.notify[:targets]) == [
             {"audit",
              {Wardrik.Notify.Webhook,
               req_options: [retry: false],
               secret: "shh",
               url: "https://hooks.example.com/wardrik"}},
             {"ops", {Wardrik.Notify.Room, channel: "slack", room: "#ops"}}
           ]

    assert config.notify[:retries] == [attempts: 5, max_wait: 20_000]
  end

  test "refuses a notify target that doesn't read", context do
    for {target, why} <- [
          {~s({channel: teams, room: "#ops"}),
           "notify.targets.ops.channel: names none of channels"},
          {~s({channel: slack, room: "#ops", to: x}),
           "notify.targets.ops: unknown options [:to], valid options are: [:channel, :room]"},
          {~s({channel: slack, room: "#ops", approvers: [maria]}),
           "notify.targets.ops: unknown options [:approvers]"},
          {~s({webhook: {url: x, method: put}}),
           "notify.targets.ops.webhook: unknown options [:method], valid options are: [:url, :secret, :req_options]"},
          {~s({email: x}), "notify.targets.ops: is a room"},
          {"1", "notify.targets.ops: is a room"}
        ] do
      yaml = "channels: {slack: {type: slack, token: x}}\nnotify: {targets: {ops: #{target}}}\n"
      assert {:error, message} = read(context, yaml)
      assert message =~ why
    end

    for {notify, why} <- [
          {~s({targets: {"a:b": {email: x}}}), "isn't a target's name"},
          {"{targets: [x]}", "notify.targets: is a target for each name"},
          {"[x]", "invalid value for :notify option: expected map"},
          {"{ops: {webhook: {url: x}}}", "notify.ops: is a target, which goes in notify.targets"},
          {"{retries: {zzz_tries: 2}}", "notify.retries.zzz_tries: isn't an option"},
          {"{zzz_retries: 2}", "notify.zzz_retries: isn't an option"},
          {"{retries: 2}", "notify: invalid value for :retries option"}
        ] do
      assert {:error, message} = read(context, "notify: #{notify}\n")
      assert message =~ why, "#{notify} said #{message}"
    end
  end

  test "reads which tools a server gates, whom it trusts, and whether workers are trusted",
       context do
    assert {:ok, config} =
             read(context, """
             mcp:
               github: {url: "https://api.githubcopilot.com/mcp/", gated: [create_*], trusted: true}
             http: {trusted_workers: true}
             """)

    assert [{"github", github}] = config.mcp
    assert github[:gated] == ["create_*"]
    assert github[:trusted] == true
    assert config.trusted_workers
  end

  test "reads roles and bindings, with the admin's", context do
    yaml = """
    org: payments
    orgs: {growth: {}}
    roles:
      reader: {rules: [{verbs: [read, events], kinds: [agent]}, {verbs: [read], kinds: [secret, ceiling]}]}
      triager: {rules: [{verbs: [ask], kinds: [agent], names: [triage]}]}
    bindings:
      - {org: payments, role: operator, subjects: [user:payments/@ana, group:payments-eng]}
      - {org: growth, role: triager, subjects: [agent:helper]}
    """

    assert {:ok, %Config{access: %{roles: roles, bindings: bindings}}} = read(context, yaml)

    assert roles["reader"] == [
             %{verbs: ["read", "events"], kinds: ["agent"], names: nil},
             %{verbs: ["read"], kinds: ["secret", "ceiling"], names: nil}
           ]

    assert roles["triager"] == [%{verbs: ["ask"], kinds: ["agent"], names: ["triage"]}]
    assert roles["operator"] == [%{verbs: ["*"], kinds: ["*"], names: nil}]
    assert roles["admin"] == [%{verbs: ["*"], kinds: ["*"], names: nil}]

    assert bindings == [
             %{org: "*", role: "admin", subjects: ["user:admin"]},
             %{
               org: "payments",
               role: "operator",
               subjects: ["user:payments/@ana", "group:payments-eng"]
             },
             %{org: "growth", role: "triager", subjects: ["agent:helper"]}
           ]
  end

  test "keeps the admin's role its own, whatever roles declares", context do
    narrowed = """
    roles:
      operator: {rules: [{verbs: [read], kinds: [agent]}]}
    """

    assert {:ok, %Config{access: %{roles: roles, bindings: [admin | _rest]}}} =
             read(context, narrowed)

    assert roles["operator"] == [%{verbs: ["read"], kinds: ["agent"], names: nil}]
    assert admin == %{org: "*", role: "admin", subjects: ["user:admin"]}
    assert roles["admin"] == [%{verbs: ["*"], kinds: ["*"], names: nil}]

    assert {:error, message} =
             read(context, "roles: {admin: {rules: [{verbs: [read], kinds: [agent]}]}}")

    assert message =~ "roles.admin: is the deployment admin's own role"
  end

  test "says where a key doesn't read", context do
    refused = [
      {"nope: 1", "unknown options [:nope], valid options are: [:org,"},
      {"org: 1", "invalid value for :org option: expected string"},
      {"deployment_keys: maybe", "invalid value for :deployment_keys option: expected boolean"},
      {"mcp: {a: {url: x, command: y}}", "mcp.a: has a url or a command, not both"},
      {"mcp: {a: {url: x, owner: acme}}", "mcp.a.owner: is the daemon's to set"},
      {"mcp: {a: {url: x, credential_name: x}}", "mcp.a.credential_name: is written credential"},
      {"mcp: {a: {url: x}}", "mcp.a: invalid value for :transport option"},
      {"mcp: {a: {url: https://x.test, gated: some}}", "mcp.a: expected :gated option to match"},
      {"mcp: {a: {url: https://x.test, trusted: yes please}}",
       "mcp.a: invalid value for :trusted option"},
      {"http: {trusted_workers: always}", "http: invalid value for :trusted_workers option"},
      {"mcp: {a: {url: https://x.test, zzz_colour: red}}", "mcp.a.zzz_colour: isn't an option"},
      {"mcp: {a: {url: https://x.test, name: red}}", "mcp.a: unknown options [:name]"},
      {"mcp: {a: {args: []}}", "mcp.a: has a command"},
      {"mcp: {a: 1}", "mcp.a: is a server's keys"},
      {"mcp: [a]", "invalid value for :mcp option: expected map"},
      {"oauth: {providers: {g: {zzz_colour: red}}}",
       "oauth.providers.g: unknown options [:zzz_colour]"},
      {"oauth: {providers: {g: {issuer: x, key: mine}}}",
       "oauth.providers.g: unknown options [:key]"},
      {"oauth: {providers: {g: {issuer: x, name: red}}}",
       "oauth.providers.g: unknown options [:name], valid options are: [:issuer,"},
      {"oauth: {providers: {g: {issuer: x, flow: carrier_pigeon}}}",
       "oauth.providers.g: invalid value for :flow option: expected one of [:browser, :device]"},
      {"oauth: {providers: {g: {scopes: [a]}}}",
       "oauth.providers.g: The g provider needs an :issuer"},
      {"oauth: {providers: {g: 1}}", "oauth.providers.g: is a map of options"},
      {"oauth: {providers: [g]}", "oauth.providers: is a provider for each name"},
      {"oauth: {page: https://x.test}",
       "oauth: unknown options [:page], valid options are: [:client_name, :req_options]"},
      {"oauth: {client_name: 1}", "oauth: invalid value for :client_name option"},
      {"oauth: 1", "invalid value for :oauth option: expected map"},
      {"channels: {Slack: {type: slack}}", "channels.Slack: isn't a channel's name"},
      {"channels: {slack: {type: teams}}", "channels.slack.type: is the kind of channel"},
      {"channels: {slack: {token: t}}", "channels.slack.type: is the kind of channel"},
      {"channels: {slack: {type: slack, owner: acme}}",
       "channels.slack: unknown options [:owner], valid options are: [:token,"},
      {"channels: {slack: {type: slack, identities: x}}",
       "channels.slack: unknown options [:identities]"},
      {"channels: {slack: {type: slack, zzz_colour: red}}",
       "channels.slack: unknown options [:zzz_colour], valid options are: [:token,"},
      {"channels: {slack: {type: slack, approvers: [maria]}}",
       "channels.slack: unknown options [:approvers]"},
      {"channels: {slack: {type: slack, members: {U1: ana}}}",
       "channels.slack: invalid map in :members option"},
      {"channels: {slack: {type: slack, members: {U1: user:ana}}}",
       "is a person in an org, as user:acme/@ana, or user:admin, not \"user:ana\""},
      {"channels: {slack: {type: slack, members: {U1: user:acme}}}",
       "is a person in an org, as user:acme/@ana, or user:admin, not \"user:acme\""},
      {"channels: {slack: {type: slack, unmapped_members: yes}}",
       "channels.slack: invalid value for :unmapped_members option"},
      {"channels: {slack: {type: slack, req_options: {zzz_frob: 1}}}",
       "channels.slack.req_options.zzz_frob: isn't an option"},
      {"channels: [a]", "invalid value for :channels option: expected map"},
      {"vault: {keys: k}", "vault: invalid value for :keys option"},
      {"http: {port: high}", "http: invalid value for :port option: is a port number"},
      {"http: {ip: here}", "http: invalid value for :ip option: is an address"},
      {"http: 1", "invalid value for :http option: expected keyword list"},
      {"defaults: 1", "invalid value for :defaults option: expected map"},
      {"brave: {key: x}", "brave: unknown options [:key], valid options are: [:api_key]"},
      {"models: {a:b: 1}",
       "models: unknown options [:a:b], valid options are: [:prices, :options, :pool]"},
      {"models: {prices: {a:b: 1}}", "models.prices.a:b: holds input and output"},
      {"models: {prices: {a:b: {zzz_per: day}}}", "models.prices.a:b.zzz_per: isn't an option"},
      {"models: {prices: {a:b: {input: 1}}}",
       "models.prices.a:b: a:b's price gives its input and output."},
      {"models: {prices: {a:b: {priced_as: nope:nope}}}",
       "models.prices.a:b: nope:nope has no price"},
      {"models: {prices: {a:b: {input: 1, output: 1, markup: lots}}}",
       "models.prices.a:b: a:b's markup is a number."},
      {"models: {options: {temprature: 1}}", "models.options: unknown options [:temprature]"},
      {"models: {options: {temperature: hot}}", "models.options: invalid value for :temperature"},
      {"models: {pool: {size: 0}}", "models.pool: invalid value for :size"},
      {"roles: {r: {rules: [{verbs: [read], kinds: [agnt]}]}}",
       "roles.r.rules.0: invalid list in :kinds option"},
      {"roles: {r: {rules: [{verbs: [read]}]}}", "roles.r.rules.0: required :kinds option"},
      {"roles: {r: {rules: [{verbs: [read], kinds: [agent], colour: red}]}}",
       "roles.r.rules.0: unknown options [:colour]"},
      {"roles: {r: {}}", "roles.r: required :rules option not found"},
      {"roles: [r]", "invalid value for :roles option: expected map"},
      {"bindings: [{org: default, role: auditor, subjects: [user:default/@ana]}]",
       "bindings.0.role: names auditor, which roles doesn't declare"},
      {"bindings: [{org: growth, role: operator, subjects: [user:default/@ana]}]",
       "bindings.0.org: names growth, which config.yaml doesn't declare"},
      {"bindings: [{org: default, role: operator, subjects: [team:ana]}]",
       "bindings.0: invalid list in :subjects option: invalid value for list element at position 0: \"team:ana\" isn't user:ORG/@PERSON, group:NAME or agent:NAME"},
      {"bindings: [{org: default, role: operator, subjects: [agent:payments/triage]}]",
       "\"agent:payments/triage\" isn't user:ORG/@PERSON, group:NAME or agent:NAME"},
      {"bindings: [{org: default, role: operator, subjects: [user:ana]}]",
       "\"user:ana\" isn't user:ORG/@PERSON, group:NAME or agent:NAME"},
      {"bindings: [{org: default, role: operator, subjects: [user:default]}]",
       "\"user:default\" isn't user:ORG/@PERSON, group:NAME or agent:NAME"},
      {~s(bindings: [{org: "*", role: operator, subjects: [agent:triage]}]),
       "bindings.0.subjects: names an agent, which is an org's; bind it in its org"},
      {"bindings: [{org: default, role: operator, subjects: [ana]}]",
       "bindings.0: invalid list in :subjects option"},
      {"bindings: [{org: default, role: operator}]", "bindings.0: required :subjects option"},
      {"bindings: {a: 1}", "invalid value for :bindings option: expected list"},
      {"org: ${MISSING}", "names ${MISSING}, which neither"},
      {"- a", "is a set of keys"},
      {"a: [", "isn't YAML"}
    ]

    for {yaml, why} <- refused do
      assert {:error, message} = read(context, yaml)
      assert message =~ why, "#{yaml} said #{message}"
    end
  end

  test "reads ${NAME} from the vault where the environment doesn't set it", context do
    write(context, "config.yaml", "org: ${ORG}\ndefaults: {model: \"${MODEL}\"}\n")
    vault = fn name -> if name == "ORG", do: {:ok, "acme"}, else: :error end
    dirs = Dirs.new(context.env)

    assert {:ok, %Config{org: "acme"}} =
             Config.read(dirs, Map.put(context.env, "MODEL", "m"), vault)

    assert {:error, why} = Config.read(dirs, context.env, vault)

    assert why =~
             "names ${MODEL}, which neither the environment, the env file nor the vault holds"

    write(context, "config.yaml", "http: {port: \"${PORT}\"}\n")
    assert {:error, why} = Config.read(dirs, context.env, fn _name -> {:ok, "1"} end)
    assert why =~ "names ${PORT}, which neither the environment nor the env file sets"
    assert {:error, _why} = Config.bootstrap(dirs, context.env)
  end

  test "reads the agents' workspaces other agents may mount, by exact name", context do
    yaml = """
    workspace:
      shared:
        agent:runbooks: {read: [agent:triage], write: [agent:ops]}
    """

    assert {:ok,
            %Config{workspace: [shared: %{"runbooks" => %{read: ["triage"], write: ["ops"]}}]}} =
             read(context, yaml)

    for shared <- [
          "{\"agent:runbooks\": {read: \"agent:acme\"}}",
          "{\"agent:runbooks\": {read: [\"agent:*\"]}}",
          "{\"agent:runbooks\": {write: [\"agent:acme/triage\"]}}",
          "{\"agent:runbooks\": {write: [triage]}}",
          "{runbooks: {read: [\"agent:triage\"]}}",
          "{\"agent:*\": {read: [\"agent:triage\"]}}",
          "{acme/runbooks: {read: [triage]}}"
        ] do
      assert {:error, why} = read(context, "workspace: {shared: #{shared}}")
      assert why =~ "is an agent, as agent:NAME, holding read and write", shared
    end

    assert {:error, why} = read(context, "workspace: {trees: {}}")
    assert why =~ "workspace: holds shared"
  end

  test "reads an empty file as the defaults", context do
    assert {:ok, %Config{org: "default"}} = read(context, "")
  end

  test "reads a config like one in use, with a query string in an endpoint", context do
    yaml = """
    org: mode
    defaults:
      model: zai_coding_plan:glm-5.3
    mcp:
      github:
        url: https://api.githubcopilot.com/mcp/x/repos/readonly
        credential: github
        only: [list_commits, get_commit, search_repositories]
    oauth:
      providers:
        github:
          resource: https://api.githubcopilot.com/mcp/
          issuer: https://github.com/login/oauth
          client_id: ${GITHUB_CLIENT_ID}
          client_secret: ${GITHUB_CLIENT_SECRET}
          scopes: [repo]
          flow: device
        google:
          issuer: https://accounts.google.com
          authorization_endpoint: https://accounts.google.com/o/oauth2/v2/auth?access_type=offline&prompt=consent
          token_endpoint: https://oauth2.googleapis.com/token
          client_id: ${GOOGLE_CLIENT_ID}
          client_secret: ${GOOGLE_CLIENT_SECRET}
          scopes:
            - https://www.googleapis.com/auth/adwords
            - https://www.googleapis.com/auth/youtube.upload
          flow: browser
    channels:
      slack:
        type: slack
        token: ${SLACK_BOT_TOKEN}
        app_token: ${SLACK_APP_TOKEN}
        members: {U1: user:acme/@jon}
    vault:
      keys: ["${WARDRIK_VAULT_KEY}"]
    brave:
      api_key: ${BRAVE_API_KEY}
    http:
      port: 4747
      ip: 127.0.0.1
    """

    env =
      Map.new(
        ~w(GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET SLACK_BOT_TOKEN
           SLACK_APP_TOKEN WARDRIK_VAULT_KEY BRAVE_API_KEY),
        &{&1, "fake-#{String.downcase(&1)}"}
      )

    assert {:ok, config} = read(context, yaml, env)

    assert {:ok, %{keys: ["fake-wardrik_vault_key"]}} =
             Config.bootstrap(Dirs.new(context.env), env)

    providers = Map.new(config.oauth[:providers])

    assert providers["google"][:authorization_endpoint] ==
             "https://accounts.google.com/o/oauth2/v2/auth?access_type=offline&prompt=consent"

    assert providers["google"][:flow] == :browser
    assert providers["google"][:client_id] == "fake-google_client_id"
    assert providers["github"][:flow] == :device
    assert config.oauth[:page] == "http://127.0.0.1:4747/oauth"
    assert config.brave == "fake-brave_api_key"
    assert config.deployment_keys == true

    assert {:ok, _opts} =
             NimbleOptions.validate(
               [
                 name: MyApp.Wardrik,
                 mcp: config.mcp,
                 channels: config.channels,
                 authorizer: {WardrikDaemon.Authorizer, config.access},
                 resolver: {WardrikDaemon.Resolver, %{}}
               ] ++
                 config.wardrik ++
                 [
                   oauth:
                     Keyword.delete(config.oauth, :providers) ++
                       [resolver: {WardrikDaemon.OAuthApps, %{}}]
                 ],
               Wardrik.schema()
             )
  end

  test "takes the libraries' options each section passes on", context do
    yaml = """
    deployment: acme-prod
    deployment_keys: false
    idle_timeout: infinity
    retention: 90
    triggers: {reconcile: 60000, req_options: {receive_timeout: 5000}}
    mcp:
      docs: {url: https://docs.test/mcp, cost: {usd: 0.01}, max_result_bytes: 4096}
    oauth:
      client_name: Acme agents
      req_options: {receive_timeout: 5000}
      providers:
        google:
          issuer: https://accounts.google.com
          client_auth: basic
          authorization_params: {access_type: offline, prompt: consent}
    channels:
      slack:
        type: slack
        signing_secret: s
        offering: Ask for @triage here.
        deciding: Ask @maria.
        req_options: {receive_timeout: 5000}
    """

    assert {:ok, config} = read(context, yaml)

    refute config.deployment_keys

    assert config.wardrik == [
             deployment: "acme-prod",
             idle_timeout: :infinity,
             retention: 90,
             triggers: [reconcile: 60_000, req_options: [receive_timeout: 5000]]
           ]

    assert [{"docs", docs}] = config.mcp
    assert docs[:cost] == [usd: 0.01]
    assert docs[:max_result_bytes] == 4096

    assert [client_name: "Acme agents", req_options: [receive_timeout: 5000]] =
             Keyword.drop(config.oauth, [:page, :providers])

    assert [{"google", google}] = config.oauth[:providers]
    assert google[:client_auth] == :basic
    assert google[:authorization_params] == %{"access_type" => "offline", "prompt" => "consent"}

    assert [{"slack", {WardrikSlack, slack}}] = config.channels
    assert slack[:installations] == :stored
    assert slack[:offering] == "Ask for @triage here."
    assert slack[:deciding] == "Ask @maria."
    assert slack[:req_options] == [receive_timeout: 5000]
  end

  test "starts no OAuth without oauth, and checks keys before the vault opens", context do
    assert {:ok, %Config{oauth: nil}} = read(context, "org: acme\n")

    assert {:ok, %Config{oauth: [page: _page, providers: [], req_options: []]}} =
             read(context, "oauth: {}\n")

    write(context, "config.yaml", "nope: 1\n")
    assert {:error, why} = Config.bootstrap(Dirs.new(context.env), context.env)
    assert why =~ "unknown options [:nope]"
  end
end
