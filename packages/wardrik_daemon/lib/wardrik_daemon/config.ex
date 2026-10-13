defmodule WardrikDaemon.Config do
  @moduledoc """
  Where the daemon keeps things, and what `config.yaml` configures.

  The daemon follows the XDG base directories, so what a person writes stays
  apart from what the daemon writes:

  | Directory | Default | What it holds |
  | --- | --- | --- |
  | `WARDRIK_CONFIG_DIR` | `$XDG_CONFIG_HOME/wardrik`, `~/.config/wardrik` | `config.yaml` or `config.yml`, and `agents/`; see `WardrikDaemon.AgentFile` |
  | `WARDRIK_DATA_DIR` | `$XDG_DATA_HOME/wardrik/store`, `~/.local/share/wardrik/store` | the store |
  | `WARDRIK_COOKIE_FILE` | `$XDG_DATA_HOME/wardrik/cookie`, `~/.local/share/wardrik/cookie` | the node's distribution cookie |
  | `WARDRIK_DATA_HOME` | `$XDG_DATA_HOME/wardrik`, `~/.local/share/wardrik` | `vault_key`, the vault's key where none is configured; see `WardrikDaemon.VaultKey` |
  | `WARDRIK_STATE_DIR` | `$XDG_STATE_HOME/wardrik`, `~/.local/state/wardrik` | `log/wardrik.log`, and `log/mcp.log` for what MCP commands write to stderr |
  | `WARDRIK_ENV_FILE` | `env` in `WARDRIK_CONFIG_DIR` | the variables `bin/wardrik` sets, one `NAME=value` a line, where its environment does not set them |

  ## config.yaml

  The file is `config.yaml`, or `config.yml`; a directory holding both is
  refused, since one of them would go unread.

      org: acme
      base_url: https://agents.acme.example

      defaults:
        model: anthropic:claude-sonnet-5
        tools: [web_search]
        policy: careful
        retries: [1, 5, 30]

      mcp:
        linear:
          url: https://mcp.linear.app/mcp
          headers:
            authorization: Bearer ${LINEAR_TOKEN}
        notes:
          command: npx
          args: [-y, "@modelcontextprotocol/server-filesystem", /srv/notes]
          only: [read_file, list_directory]
        github:
          url: https://api.githubcopilot.com/mcp/
          credential: github
        docs:
          url: https://docs.example.com/mcp
          org: "*"

      oauth:
        providers:
          github:
            resource: https://api.githubcopilot.com/mcp/
            issuer: https://github.com/login/oauth
            client_id: ${GITHUB_CLIENT_ID}
            client_secret: ${GITHUB_CLIENT_SECRET}
            scopes: [repo]

      vault:
        keys: ["${WARDRIK_VAULT_KEY}"]

      channels:
        slack:
          type: slack
          token: ${SLACK_BOT_TOKEN}
          app_token: ${SLACK_APP_TOKEN}
          admins: ["@jon"]

      notify:
        ops:
          channel: slack
          room: "#ops"
          approvers: ["@maria"]
        audit:
          webhook:
            url: https://hooks.example.com/wardrik
            secret: ${WARDRIK_WEBHOOK_SECRET}

      storage:
        s3:
          bucket: wardrik
          endpoint: https://<account>.r2.cloudflarestorage.com
          region: auto
          access_key_id: ${R2_ACCESS_KEY_ID}
          secret_access_key: ${R2_SECRET_ACCESS_KEY}

  It is YAML 1.2, the same YAML an agent file's frontmatter is written in.

  `${NAME}` in any string is replaced with that environment variable, or,
  where the environment does not set it, with the deployment's secret of that
  name in the vault, which `wardrik vault put NAME` seals. Either way the file
  itself need hold no secret. `storage`, `cluster`, `http` and `vault` read
  the environment alone: the store holds the vault, the cluster and the HTTP
  API's settings are read as the node boots, before the vault can be, and the
  vault cannot unlock itself.

  The environment is the one `bin/wardrik` runs in, with what the env file
  sets where that environment does not; see `env_file/1`. A variable that is
  not set is refused with where to set it.

  `org` is the deployment's org: the one an agent belongs to where its file
  names none, and the one the CLI finds an agent in when it is named without
  an org. It is `default` unless set; `org/0` reads it.

  `base_url` is the deployment's address, as people and services reach it
  through whatever is in front of the daemon: an `https://` URL, or
  `http://` on loopback. A webhook trigger is sent requests under it, at
  `/v1/hooks/`, which `wardrik triggers` prints, and `oauth.redirect.url`
  is `{base_url}/oauth` where it says no other, so the front passes
  `/oauth/` to the callback and the rest to the HTTP API. Without it the
  deployment is this machine's loopback, where the HTTP API listens;
  `base_url/0` reads it.

  `tools` lists what one call to a tool costs, in US dollars, for a tool
  that says nothing of what it cost itself, such as an MCP server's: each
  call the tool answers, failed or not, carries that price as its cost in
  its `tool_call.completed` event, and a budget counts it. A tool is named
  as a policy names one, `web_search` or `github/create_issue`, with `*`
  for any run of characters; a name given whole wins over a pattern, and a
  longer pattern over a shorter.

      tools:
        web_search:
          price: 0.005
        github/*:
          price: 0.001

  `defaults` is what an agent is given where nothing else says: one
  `wardrik agent spawn` writes a file for, and one the TUI starts. It takes
  `model`, `tools`, `policy`, `timeout`, `idle_timeout`, `max_iterations`,
  `retries` and `compaction`, as an agent file does; see
  `WardrikDaemon.AgentFile`. `idle_timeout` and `retries` hold for every
  agent that sets none of its own: 900 seconds, and `[1, 5]`, where they are
  not set. `wardrik init` writes it with the model it
  chose.

  An MCP server and a notify target each serve one org's agents, the
  deployment's own, unless its `org` names another, a list of them, or `*`
  for every org. An agent cannot reach a server, or route its notices to a
  target, that is not its org's.

  A server with `command` is started as a command, with `args`, `env` and
  `cwd` beside it; one with `url` is reached over HTTP, with `headers`. Either
  takes `only`, `except`, `prefix`, `timeout` in seconds, `max_result_bytes`,
  `credential`, the name of the credential it is reached with, along with
  `credential_header`, `credential_scheme` and `credential_env`, `gated`,
  the tools whose calls wait on a person unless a rule allows them by name,
  every tool the server does not mark read-only unless set, and
  `trusted: true` for a server whose answers are the deployment's own, so
  they are not labelled `outside`. See `WardrikMCP.Server`.

  A credential is kept in the vault, sealed, and found for each call the most
  specific first: the agent's user's, sealed with `wardrik vault put NAME
  --user USER`; its org's, with `--org ORG`; then the deployment's, with
  `wardrik vault put NAME`. Where none holds it and `oauth` has a provider of
  the same name, the agent's user, or its org where it has no user, is asked
  to connect an account, which is kept in the vault from then on.

  `oauth` takes `client`, `redirect` and `providers`, as `WardrikOAuth.Supervisor`
  takes them. `redirect.url` is where a provider sends the browser back to,
  each under `callback/NAME`: an `https://` URL the deployment serves from
  something in front of the daemon, which passes requests on to where
  `redirect.ip` and `redirect.port` say, or, without it, this machine's
  loopback; see `WardrikOAuth.Callback`. `vault` takes `keys`, as `WardrikVault` does; without them,
  or `WARDRIK_VAULT_KEY`, the vault's key is `vault_key` in the data home,
  which the first `wardrik vault put` asks to make. `ssh` takes
  `port` and `ip`, as `WardrikDaemon.SSH` does, and so does `http`, as `WardrikHTTP`
  does, with `trusted_workers: true` where tool workers' answers are the
  deployment's own.

  `cluster` takes `nodes`, or `dns` and `size`, as `WardrikDaemon.Cluster`
  describes them, and joins this daemon to others.

  `storage` names the store everything is kept in, one of:

    * `postgres`, with `url`, a `postgres://` URL, as `WardrikEcto.Store`
      takes it: the daemon connects with a repo of its own and creates the
      table as it starts.
    * `s3`, with `bucket`, `endpoint`, `access_key_id` and `secret_access_key`,
      and optionally `region` and `prefix`, as `WardrikS3.Store` takes them.

  Without `storage`, the store is `WardrikStore.EKV`, on the node's disk under
  `WARDRIK_DATA_DIR`. A release reads `storage`, `cluster` and `http` as it
  boots, before anything starts, and the rest once the store runs; see
  `boot/1`.

  `channels` names the chat media agents are reached through, each by a name
  of the deployment's own, with its `type`: the adapter, as `WardrikChannel`
  finds those the release holds, and its `org`, whose agents it may offer
  in a room: the deployment's own unless it says, or `*` for every org's.
  Someone in a room no agent is offered in may create one there, from
  `defaults`, where `defaults` name a policy, unless the channel's `create`
  is `false`. A channel's `approvers` are asked what an agent asks in its
  threads, as the channel names people, directly where the channel can
  reach a person, and its `admins`, named alike, may change its orgs'
  agents; see `WardrikDaemon.Grants` for what each may do.
  The rest of a channel's settings are its adapter's, which reads them; see
  `WardrikChannel`. An agent is offered in a channel's rooms where its file
  names the channel; see `WardrikDaemon.AgentFile`.

  `notify` names targets an agent's `notify` routes to, each one a
  `channel` of `channels` and a `room` in it, with who may answer it as
  `approvers`, as `WardrikChannel.Notices` takes them; or a `webhook`, with
  `url` and optionally `secret`, as `WardrikNotify.Webhook` takes them.

  `read/1` refuses a file with a variable that is not set, a key nothing takes,
  a server that is neither a command nor a URL, or a server whose name or
  `prefix` holds `__`, and says where.

  ## Where the settings go

  The daemon keeps what it read in its own application environment, by the
  module each section is for, and starts each package with its section as
  options: `WardrikMCP.Supervisor` with what `mcp` says, `WardrikOAuth.Supervisor`
  with `oauth`, and so on. `settings/1` reads them back. A release's own
  configuration may give a module settings of its own under `:wardrik_daemon`,
  which `config.yaml` is merged over:

      config :wardrik_daemon, WardrikVault, environment: ["SEARCH_API_KEY"]
  """

  alias WardrikDaemon.Cluster.DNSPoll
  alias WardrikDaemon.Cluster.Epmd
  alias WardrikDaemon.Cluster.Topology

  @typedoc "Settings by the module they are for, which the daemon starts with them."
  @type settings() :: [{module(), keyword()}]

  @transport ~w(command args env cwd url headers)a
  @server @transport ++
            ~w(only except prefix timeout max_result_bytes gated trusted credential credential_header credential_scheme credential_env)a
  @oauth ~w(client redirect providers)a
  @client ~w(name document_url client_uri logo_uri policy_uri tos_uri)a
  @redirect ~w(url ip port open)a
  @provider ~w(resource issuer client_id client_secret scopes authorization_params flow)a
  @vault ~w(keys)a
  @listener ~w(port ip)a
  @stores %{
    "postgres" => {WardrikEcto.Store, ~w(url), ~w(url)},
    "s3" =>
      {WardrikS3.Store, ~w(bucket endpoint region prefix access_key_id secret_access_key),
       ~w(bucket endpoint access_key_id secret_access_key)}
  }
  @notifiers %{
    "webhook" => {WardrikNotify.Webhook, ~w(url secret), ~w(url)}
  }

  @target "is a webhook, or a channel and a room in it, with the org it tells"

  @store_settings ~w(url bucket endpoint region prefix access_key_id secret_access_key)a
  @store_urls %{
    "url" => {~w(postgres postgresql), "a postgres:// URL"},
    "endpoint" => {~w(http https), "an https:// URL"}
  }

  @settings Map.new(
              @server ++
                @oauth ++
                @client ++ @redirect ++ @provider ++ @vault ++ @listener ++ @store_settings,
              &{Atom.to_string(&1), &1}
            )

  @transport_keys Enum.map(@transport, &Atom.to_string/1)
  @server_keys Enum.map(@server, &Atom.to_string/1)
  @oauth_keys Enum.map(@oauth, &Atom.to_string/1)
  @client_keys Enum.map(@client, &Atom.to_string/1)
  @redirect_keys Enum.map(@redirect, &Atom.to_string/1)
  @provider_keys Enum.map(@provider, &Atom.to_string/1)
  @vault_keys Enum.map(@vault, &Atom.to_string/1)
  @listener_keys Enum.map(@listener, &Atom.to_string/1)
  @credential "the name of a credential, such as github: letters, digits, ., - and _"

  # The sections a read gives no name from the vault, and why.
  @environment_only %{
    "storage" => "storage reads the environment alone, since the vault is kept in the store",
    "cluster" =>
      "cluster reads the environment alone, as the node boots, before the vault can be",
    "http" => "http reads the environment alone, as the node boots, before the vault can be",
    "vault" => "vault reads the environment alone, since the vault cannot unlock itself"
  }
  @org "default"
  @segment "an org holds no / or whitespace and does not begin with @ or _"

  @doc "The deployment's org, as `config.yaml` names it, or `#{@org}` where it names none."
  @spec org() :: String.t()
  def org, do: WardrikDaemon |> settings() |> Keyword.get(:org, @org)

  @doc """
  The deployment's address, as `config.yaml`'s `base_url` names it, or where
  it names none, the HTTP API on this machine's loopback.
  """
  @spec base_url() :: String.t()
  def base_url do
    Keyword.get_lazy(settings(WardrikDaemon), :base_url, fn ->
      "http://127.0.0.1:#{Keyword.get(settings(WardrikHTTP), :port, 4747)}"
    end)
  end

  @doc """
  What the daemon keeps for `module`: what `config.yaml` says of it, merged
  over what the release's configuration gives it. `[]` where neither says
  anything.
  """
  @spec settings(module()) :: keyword()
  def settings(module) when is_atom(module), do: Application.get_env(:wardrik_daemon, module, [])

  @doc "Where `config.yaml` is read from: `WARDRIK_CONFIG_DIR`, or `wardrik` under the XDG config home."
  @spec config_dir() :: Path.t()
  def config_dir, do: dir("WARDRIK_CONFIG_DIR", "XDG_CONFIG_HOME", "~/.config")

  @doc "Where what the daemon makes for itself is kept: `wardrik` under the XDG data home."
  @spec data_dir() :: Path.t()
  def data_dir, do: dir("WARDRIK_DATA_HOME", "XDG_DATA_HOME", "~/.local/share")

  @doc "Where logs are written: `WARDRIK_STATE_DIR`, or `wardrik` under the XDG state home."
  @spec state_dir() :: Path.t()
  def state_dir, do: dir("WARDRIK_STATE_DIR", "XDG_STATE_HOME", "~/.local/state")

  defp dir(own, xdg, default) do
    System.get_env(own) || Path.join(System.get_env(xdg) || Path.expand(default), "wardrik")
  end

  @doc """
  The file `bin/wardrik` reads variables from, beside `config.yaml` in
  `config_dir` unless `WARDRIK_ENV_FILE` names another.
  """
  @spec env_file(Path.t()) :: Path.t()
  def env_file(config_dir), do: System.get_env("WARDRIK_ENV_FILE") || Path.join(config_dir, "env")

  @doc """
  The config file in `config_dir`: `config.yaml`, or `config.yml` where that
  is the one there. Where neither is, `config.yaml`, which `read/1` finds
  empty.
  """
  @spec file(Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def file(config_dir) do
    case Enum.filter(["config.yaml", "config.yml"], &File.exists?(Path.join(config_dir, &1))) do
      [_yaml, _yml] -> {:error, "#{config_dir} holds both config.yaml and config.yml; keep one"}
      [name] -> {:ok, Path.join(config_dir, name)}
      [] -> {:ok, Path.join(config_dir, "config.yaml")}
    end
  end

  @doc """
  The settings `file` configures, or none where there is no file.

  `${NAME}` reads the environment. Given `:vault`, a name the environment
  does not set is read from it: a function answering the deployment's secret
  of that name, or `nil`. `storage`, `cluster` and `vault` read the
  environment alone, and say why where a name is not set. `:only` reads only
  the sections it names.
  """
  @spec read(Path.t(), keyword()) :: {:ok, settings()} | {:error, String.t()}
  def read(file, opts \\ []) do
    case File.read(file) do
      {:ok, text} -> decode(text, file, opts)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, "#{file}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  What a release keeps as it boots, before anything starts: the store
  `storage` names, the cluster `cluster` describes, and the HTTP API's `http`,
  for what the release starts before the daemon. A store kept on the nodes,
  as it is without `storage`, counts its quorum over the cluster's size.

      for {module, settings} <- WardrikDaemon.Config.boot(settings),
          do: config(:wardrik_daemon, module, settings)
  """
  @spec boot(settings()) :: settings()
  def boot(settings) do
    cluster = Keyword.get(settings, WardrikDaemon.Cluster, [])
    store = Keyword.get(settings, WardrikStore, [])

    store =
      case {Keyword.has_key?(store, :adapter), cluster[:size]} do
        {false, size} when is_integer(size) -> Keyword.put(store, :cluster_size, size)
        _kept_elsewhere_or_alone -> store
      end

    for {module, settings} <- [
          {WardrikDaemon.Cluster, cluster},
          {WardrikStore, store},
          {WardrikHTTP, Keyword.get(settings, WardrikHTTP, [])}
        ],
        settings != [],
        do: {module, settings}
  end

  @doc """
  Merges each module's settings over what the daemon keeps for it; see
  `settings/1`. The store's are left out: it is running by then, and `boot/1`
  gives them to a release before it starts.
  """
  @spec apply(settings()) :: :ok
  def apply(settings) do
    settings
    |> Keyword.delete(WardrikStore)
    |> Enum.each(fn {module, opts} ->
      Application.put_env(:wardrik_daemon, module, Keyword.merge(settings(module), opts))
    end)
  end

  defp decode(text, file, opts) do
    case YamlElixir.read_from_string(text) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, document} ->
        document = document |> table!([]) |> only(opts[:only])
        env = env_file(Path.dirname(file))
        secret = &secret(&1, &2, opts[:vault], env)
        {:ok, document |> interpolate([], secret) |> sections()}

      {:error, error} ->
        {:error, "#{file}: is not YAML: #{Exception.message(error)}"}
    end
  catch
    {:invalid, path, message} -> {:error, "#{file}: #{Enum.join(path, ".")} #{message}"}
  end

  defp sections(document) do
    {org, document} = Map.pop(document, "org")
    {base_url, document} = Map.pop(document, "base_url")
    org = org!(org)
    base_url = base_url(base_url)

    [
      {WardrikDaemon, [org: org] ++ base_url}
      | document |> sections(org) |> through_channels() |> addressed(base_url)
    ]
  end

  defp base_url(nil), do: []
  defp base_url(url), do: [base_url: redirect_url!(url, ["base_url"])]

  # A setting further down that names no address of its own is under the
  # deployment's.
  defp addressed(sections, []), do: sections

  defp addressed(sections, base_url: base_url) do
    Enum.map(sections, fn
      {WardrikOAuth, oauth} ->
        redirect = Keyword.put_new(Keyword.get(oauth, :redirect, []), :url, base_url <> "/oauth")
        {WardrikOAuth, Keyword.put(oauth, :redirect, redirect)}

      section ->
        section
    end)
  end

  defp sections(document, org) do
    Enum.map(document, fn
      {"defaults", defaults} ->
        {WardrikDaemon.Agents, defaults: defaults(defaults)}

      {"tools", tools} ->
        {WardrikDaemon.AgentFile, tool_prices: prices(table!(tools, ["tools"]))}

      {"mcp", servers} ->
        {WardrikMCP, servers: servers(table!(servers, ["mcp"]), org)}

      {"oauth", oauth} ->
        {WardrikOAuth, oauth(table!(oauth, ["oauth"]))}

      {"vault", vault} ->
        {WardrikVault, vault(table!(vault, ["vault"]))}

      {"ssh", ssh} ->
        {WardrikDaemon.SSH, listener(ssh, "ssh")}

      {"http", http} ->
        {WardrikHTTP, http(http)}

      {"notify", targets} ->
        {WardrikNotify, targets: targets(table!(targets, ["notify"]), org)}

      {"channels", channels} ->
        {WardrikChannel, channels(table!(channels, ["channels"]), org)}

      {"cluster", cluster} ->
        {WardrikDaemon.Cluster, cluster(table!(cluster, ["cluster"]))}

      {"storage", storage} ->
        {WardrikStore, storage(table!(storage, ["storage"]))}

      {section, _value} ->
        invalid!(
          [section],
          "is not a section; expected org, tools, defaults, mcp, oauth, vault, ssh, http, " <>
            "channels, notify, cluster or storage"
        )
    end)
  end

  # -- tools -----------------------------------------------------------------

  defp prices(tools) do
    Map.new(tools, fn {name, settings} ->
      path = ["tools", name]
      tool_pattern!(name, path)
      settings = table!(settings, path)
      known!(settings, ["price"], path)
      {name, price!(Map.get(settings, "price"), path)}
    end)
  end

  defp tool_pattern!(name, path) do
    case WardrikPolicy.Pattern.parse(name) do
      {:ok, pattern} ->
        if WardrikPolicy.Pattern.argument?(pattern),
          do: invalid!(path, "names the tool alone, not what its calls act on")

      {:error, message} ->
        invalid!(path, message)
    end
  end

  defp price!(price, _path) when is_number(price) and price >= 0, do: price

  defp price!(_price, path),
    do: invalid!(path ++ ["price"], "is a price in US dollars, such as 0.005")

  # -- org -------------------------------------------------------------------

  defp org!(nil), do: @org

  defp org!(org) do
    if Wardrik.AgentID.segment?(org),
      do: org,
      else: invalid!(["org"], "is #{inspect(org)}, which is not an org; #{@segment}")
  end

  # The orgs whose agents reach a server, or hear from a target: the
  # deployment's own unless it says, or every org's for `*`.
  defp orgs(nil, org, _path), do: [org]
  defp orgs("*", _org, _path), do: :all
  defp orgs(name, org, path) when is_binary(name), do: orgs([name], org, path)

  defp orgs([_ | _] = names, _org, path) do
    if Enum.all?(names, &Wardrik.AgentID.segment?/1),
      do: names,
      else: invalid!(path, "is an org, a list of them, or * for every org; #{@segment}")
  end

  defp orgs(_value, _org, path),
    do: invalid!(path, "is an org, a list of them, or * for every org")

  # -- mcp -------------------------------------------------------------------

  defp servers(servers, org) do
    Enum.map(servers, fn {name, server} ->
      path = ["mcp", name]
      {orgs, server} = Map.pop(table!(server, path), "org")
      known!(server, @server_keys ++ ["org"], path)
      prefix!(Map.get(server, "prefix", name), path)

      {name(name),
       [transport: transport(server, path), orgs: orgs(orgs, org, path ++ ["org"])] ++
         Enum.map(Map.drop(server, @transport_keys), &server_option(&1, path))}
    end)
  end

  defp prefix!("workers", path),
    do:
      invalid!(
        path,
        "names its tools with workers, which tool workers' tools are named with; give it another prefix"
      )

  defp prefix!(prefix, path) when is_binary(prefix) do
    if String.contains?(prefix, "__"),
      do: invalid!(path, "names its tools with #{prefix}, and a server's prefix may not hold __")
  end

  defp prefix!(prefix, path),
    do: invalid!(path, "names its tools with #{inspect(prefix)}, which is not text")

  defp transport(%{"command" => _, "url" => _}, path),
    do: invalid!(path, "has both command and url; a server is one or the other")

  defp transport(%{"command" => command} = server, _path),
    do: {:stdio, [command: command] ++ take(server, ~w(args env cwd))}

  defp transport(%{"url" => url} = server, _path),
    do: {:streamable_http, [base_url: url] ++ take(server, ~w(headers))}

  defp transport(_server, path), do: invalid!(path, "needs a command or a url")

  defp server_option({"timeout", seconds}, _path) when is_integer(seconds) and seconds > 0,
    do: {:timeout, :timer.seconds(seconds)}

  defp server_option({"timeout", _seconds}, path),
    do: invalid!(path ++ ["timeout"], "is a whole number of seconds")

  defp server_option({"credential", ref}, path), do: {:credential, credential(ref, path)}

  defp server_option({"gated", gated}, _path) when is_boolean(gated), do: {:gated, gated}

  defp server_option({"gated", names}, path) when is_list(names) do
    if Enum.all?(names, &is_binary/1),
      do: {:gated, names},
      else: invalid!(path ++ ["gated"], "is true, false, or a list of the server's tool names")
  end

  defp server_option({"gated", _gated}, path),
    do: invalid!(path ++ ["gated"], "is true, false, or a list of the server's tool names")

  defp server_option({"trusted", trusted}, _path) when is_boolean(trusted),
    do: {:trusted, trusted}

  defp server_option({"trusted", _trusted}, path),
    do: invalid!(path ++ ["trusted"], "is true or false")

  defp server_option({key, value}, _path), do: {setting(key), value}

  defp credential(name, path) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, name),
      do: name,
      else: invalid!(path ++ ["credential"], "is #{inspect(name)}, which is not #{@credential}")
  end

  defp credential(_name, path), do: invalid!(path ++ ["credential"], "is #{@credential}")

  # -- defaults --------------------------------------------------------------

  # Kept as the file writes them, to be written into an agent file and read
  # as one.
  defp defaults(defaults) do
    defaults = table!(defaults, ["defaults"])

    case WardrikDefinition.check_defaults(defaults) do
      :ok -> defaults
      {:error, key, message} -> invalid!(["defaults", key], message)
    end
  end

  # -- oauth and vault -------------------------------------------------------

  defp oauth(oauth) do
    known!(oauth, @oauth_keys, ["oauth"])

    Enum.map(oauth, fn
      {"client", client} ->
        {:client, options(client, @client_keys, ["oauth", "client"])}

      {"redirect", redirect} ->
        {:redirect, redirect(redirect)}

      {"providers", providers} ->
        {:providers, providers(table!(providers, ["oauth", "providers"]))}
    end)
  end

  defp redirect(redirect) do
    path = ["oauth", "redirect"]
    redirect = table!(redirect, path)
    known!(redirect, @redirect_keys, path)

    Enum.map(redirect, fn
      {"url", url} -> {:url, redirect_url!(url, path ++ ["url"])}
      {"ip", ip} -> {:ip, address!(ip, path ++ ["ip"])}
      {"port", port} when is_integer(port) and port in 1..65_535 -> {:port, port}
      {"port", _port} -> invalid!(path ++ ["port"], "is a port number")
      {"open", open} when is_boolean(open) -> {:open, open}
      {"open", _open} -> invalid!(path ++ ["open"], "is true or false")
    end)
  end

  @redirect_url "is an https:// URL, or http:// on loopback, with no query or fragment"

  # Where providers send the browser back to: https, or http on this
  # machine's own loopback, with nothing after its path.
  defp redirect_url!(url, path) when is_binary(url) do
    if redirect_url?(URI.parse(url)),
      do: String.trim_trailing(url, "/"),
      else: invalid!(path, @redirect_url)
  end

  defp redirect_url!(_url, path), do: invalid!(path, @redirect_url)

  defp redirect_url?(%URI{userinfo: nil, query: nil, fragment: nil} = uri),
    do: secure?(uri.scheme, uri.host)

  defp redirect_url?(_uri), do: false

  defp secure?("https", host), do: host not in [nil, ""]
  defp secure?("http", host), do: host in ["127.0.0.1", "localhost", "::1"]
  defp secure?(_scheme, _host), do: false

  defp providers(providers) do
    Enum.map(providers, fn {name, provider} ->
      path = ["oauth", "providers", name]

      {name(name),
       provider
       |> options(@provider_keys, path)
       |> flow(path)
       |> secret(path)
       |> authorization_params(path)}
    end)
  end

  defp secret(provider, path) do
    if Keyword.has_key?(provider, :client_secret) and not Keyword.has_key?(provider, :issuer),
      do:
        invalid!(
          path ++ ["client_secret"],
          "is sent only to an issuer the provider names; add issuer"
        ),
      else: provider
  end

  defp authorization_params(provider, path) do
    path = path ++ ["authorization_params"]

    case Keyword.fetch(provider, :authorization_params) do
      {:ok, params} when is_map(params) ->
        Enum.each(params, &authorization_param(&1, path))
        Keyword.put(provider, :authorization_params, Map.new(params, &text/1))

      {:ok, _params} ->
        invalid!(path, "is a table of names to the values to send")

      :error ->
        provider
    end
  end

  defp authorization_param({name, value}, path) do
    cond do
      name in WardrikOAuth.Flow.own_params() ->
        invalid!(path ++ [name], "is one Wardrik sets itself")

      is_binary(value) or is_number(value) or is_boolean(value) ->
        :ok

      true ->
        invalid!(path ++ [name], "is a string, a number or true or false")
    end
  end

  defp text({name, value}), do: {name, to_string(value)}

  defp flow(provider, path) do
    case Keyword.fetch(provider, :flow) do
      {:ok, flow} when flow in ["auto", "browser", "device"] ->
        Keyword.put(provider, :flow, WardrikOAuth.Provider.flow!(flow))

      {:ok, _flow} ->
        invalid!(path ++ ["flow"], "is auto, browser or device")

      :error ->
        provider
    end
  end

  defp vault(vault), do: options(vault, @vault_keys, ["vault"])

  # -- listeners -------------------------------------------------------------

  defp http(http) do
    http = table!(http, ["http"])
    known!(http, @listener_keys ++ ["trusted_workers"], ["http"])
    {trusted, listener} = Map.pop(http, "trusted_workers")

    case trusted do
      nil -> listener(listener, "http")
      trusted when is_boolean(trusted) -> [trusted_workers: trusted] ++ listener(listener, "http")
      _other -> invalid!(["http", "trusted_workers"], "is true or false")
    end
  end

  defp listener(listener, section) do
    listener = table!(listener, [section])
    known!(listener, @listener_keys, [section])

    Enum.map(listener, fn
      {"port", port} when is_integer(port) and port in 1..65_535 -> {:port, port}
      {"port", _port} -> invalid!([section, "port"], "is a port number")
      {"ip", ip} -> {:ip, address!(ip, [section, "ip"])}
    end)
  end

  defp address!(ip, path) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, address} -> address
      {:error, _reason} -> invalid!(path, "is an address, such as 127.0.0.1 or 0.0.0.0")
    end
  end

  defp address!(_ip, path), do: invalid!(path, "is an address, such as 127.0.0.1 or 0.0.0.0")

  # -- notify ----------------------------------------------------------------

  defp targets(targets, org) do
    Enum.map(targets, fn {name, target} ->
      path = ["notify", name]
      {orgs, target} = Map.pop(table!(target, path), "org")
      {module, options} = target(target, path)
      {name(name), {module, options ++ [orgs: orgs(orgs, org, path ++ ["org"])]}}
    end)
  end

  # A room in a channel, which `through_channels/1` finds by its name.
  defp target(%{"channel" => _} = target, path) do
    known!(target, ~w(channel room approvers), path)

    for key <- ~w(channel room),
        not (is_binary(target[key]) and target[key] != ""),
        do: invalid!(path ++ [key], "is required")

    approvers = Map.get(target, "approvers", [])
    approvers!(approvers, path ++ ["approvers"])

    {WardrikChannel.Notices,
     channel: target["channel"], room: target["room"], approvers: approvers}
  end

  defp target(target, path) do
    case Map.to_list(target) do
      [{kind, options}] -> notifier(kind, options, path ++ [kind])
      _other -> invalid!(path, @target)
    end
  end

  defp notifier(kind, options, path) do
    case Map.fetch(@notifiers, kind) do
      {:ok, {module, keys, required}} ->
        options = table!(options, path)
        known!(options, keys, path)

        for key <- required,
            not Map.has_key?(options, key),
            do: invalid!(path ++ [key], "is required")

        # reach:disable-next-line unsafe_atom_creation -- keys checked against the notifier's list
        {module, Enum.map(options, fn {key, value} -> {String.to_atom(key), value} end)}

      :error ->
        invalid!(Enum.drop(path, -1), @target)
    end
  end

  # -- channels --------------------------------------------------------------

  # Each channel, and the orgs whose agents it may offer.
  defp channels(channels, org) do
    read =
      Enum.map(channels, fn {name, channel} ->
        path = ["channels", name]
        {type, settings} = Map.pop(table!(channel, path), "type")
        {orgs, settings} = Map.pop(settings, "org")
        {creates, settings} = Map.pop(settings, "create", true)
        {approvers, settings} = Map.pop(settings, "approvers", [])
        {admins, settings} = Map.pop(settings, "admins", [])
        adapter = adapter!(type, path ++ ["type"])

        unless is_boolean(creates),
          do: invalid!(path ++ ["create"], "is true or false")

        approvers!(approvers, path ++ ["approvers"])
        approvers!(admins, path ++ ["admins"])

        case adapter.config(settings) do
          {:ok, options} ->
            {name(name),
             %{
               channel: {adapter, options},
               orgs: orgs(orgs, org, path ++ ["org"]),
               creates: creates,
               approvers: approvers,
               admins: admins
             }}

          {:error, at, message} ->
            invalid!(path ++ at, message)
        end
      end)

    [
      channels: for({name, channel} <- read, do: {name, channel.channel}),
      orgs: for({name, channel} <- read, do: {name, channel.orgs}),
      creates: for({name, channel} <- read, do: {name, channel.creates}),
      approvers: for({name, channel} <- read, do: {name, channel.approvers}),
      admins: for({name, channel} <- read, do: {name, channel.admins})
    ]
  end

  defp approvers!(approvers, path) do
    unless is_list(approvers) and Enum.all?(approvers, &is_binary/1),
      do: invalid!(path, "is a list of who may answer, as the channel names them")
  end

  defp adapter!(type, path) do
    with true <- is_binary(type),
         {:ok, adapter} <- WardrikChannel.adapter(type) do
      adapter
    else
      _unknown ->
        case WardrikChannel.adapters() |> Map.keys() |> Enum.sort() do
          [] -> invalid!(path, "is the kind of channel, and this release has none")
          types -> invalid!(path, "is the kind of channel: #{Enum.join(types, ", ")}")
        end
    end
  end

  # A notify target in a channel posts through it, as `channels` holds it.
  defp through_channels(sections) do
    channels = sections |> Keyword.get(WardrikChannel, []) |> Keyword.get(:channels, [])

    Enum.map(sections, fn
      {WardrikNotify, notify} ->
        {WardrikNotify,
         Keyword.update!(notify, :targets, &Enum.map(&1, fn t -> through(t, channels) end))}

      section ->
        section
    end)
  end

  defp through({name, {WardrikChannel.Notices, options}}, channels) do
    named = options[:channel]

    case Enum.find(channels, fn {channel, _adapter} -> Atom.to_string(channel) == named end) do
      {_name, channel} ->
        {name, {WardrikChannel.Notices, Keyword.put(options, :channel, channel)}}

      nil ->
        invalid!(
          ["notify", Atom.to_string(name), "channel"],
          "is #{named}, which config.yaml's channels does not name"
        )
    end
  end

  defp through(target, _channels), do: target

  # -- cluster ---------------------------------------------------------------

  defp cluster(%{"nodes" => _, "dns" => _}),
    do: invalid!(["cluster"], "has both nodes and dns; a cluster is found one way")

  defp cluster(%{"nodes" => names} = cluster) do
    known!(cluster, ["nodes"], ["cluster"])
    nodes = cluster_nodes(names)

    [
      nodes: nodes,
      size: length(nodes),
      topologies: [
        %Topology{name: "nodes", strategy: %Epmd{hosts: nodes}, polling_interval: 2_000}
      ]
    ]
  end

  defp cluster(%{"dns" => query} = cluster) do
    known!(cluster, ["dns", "size"], ["cluster"])

    unless is_binary(query) and query != "",
      do: invalid!(["cluster", "dns"], "is the DNS name the cluster's nodes resolve to")

    case Map.get(cluster, "size") do
      size when is_integer(size) and size > 0 ->
        [size: size, topologies: [%Topology{name: "dns", strategy: %DNSPoll{query: query}}]]

      nil ->
        invalid!(["cluster", "size"], "is required with dns: how many nodes the cluster has")

      _size ->
        invalid!(["cluster", "size"], "is a whole number of nodes")
    end
  end

  defp cluster(cluster) do
    known!(cluster, ["nodes", "dns"], ["cluster"])
    invalid!(["cluster"], "names its nodes, or the dns name they resolve to, with its size")
  end

  defp cluster_nodes([_ | _] = names) do
    names = Enum.with_index(names, &{&1, ["cluster", "nodes", "#{&2}"]})

    for {name, path} <- names,
        not (is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_-]+(@[^@\s]+)?$/, name)),
        do:
          invalid!(
            path,
            "is #{inspect(name)}, which is not a node name such as a or wardrik@box1"
          )

    case Enum.split_with(names, fn {name, _path} -> String.contains?(name, "@") end) do
      {_full, []} ->
        :ok

      {[], _short} ->
        :ok

      {_full, _short} ->
        invalid!(["cluster", "nodes"], "mixes names on this machine with full names")
    end

    nodes = Enum.map(names, fn {name, _path} -> WardrikConsole.Nodes.named(name) end)

    case nodes -- Enum.uniq(nodes) do
      [] ->
        nodes

      [twice | _] ->
        invalid!(["cluster", "nodes"], "names #{WardrikConsole.Nodes.display(twice)} twice")
    end
  end

  defp cluster_nodes(_names),
    do: invalid!(["cluster", "nodes"], "is a list of node names, such as [a, b, c]")

  # -- storage ---------------------------------------------------------------

  defp storage(storage) do
    known!(storage, Map.keys(@stores), ["storage"])

    case Map.to_list(storage) do
      [] ->
        []

      [{kind, options}] ->
        {adapter, keys, required} = Map.fetch!(@stores, kind)
        path = ["storage", kind]
        options = table!(options, path)
        known!(options, keys, path)

        for key <- required,
            not Map.has_key?(options, key),
            do: invalid!(path ++ [key], "is required")

        [adapter: adapter] ++
          Enum.map(options, fn {key, value} -> store_option(key, value, path) end)

      _several ->
        invalid!(["storage"], "names one store, postgres or s3")
    end
  end

  defp store_option(key, value, path) when is_binary(value) and value != "" do
    with {:ok, url} <- Map.fetch(@store_urls, key), do: url!(value, url, path ++ [key])
    {setting(key), value}
  end

  defp store_option(key, _value, path), do: invalid!(path ++ [key], "is text")

  defp url!(value, {schemes, what}, path) do
    %URI{scheme: scheme, host: host} = URI.parse(value)
    unless scheme in schemes and host not in [nil, ""], do: invalid!(path, "is #{what}")
  end

  # -- tables ----------------------------------------------------------------

  defp options(table, keys, path) do
    table = table!(table, path)
    known!(table, keys, path)
    Enum.map(table, fn {key, value} -> {setting(key), value} end)
  end

  defp take(table, keys) do
    for key <- keys, Map.has_key?(table, key), do: {setting(key), Map.fetch!(table, key)}
  end

  defp setting(key), do: Map.fetch!(@settings, key)

  # reach:disable-next-line unsafe_atom_creation -- config.yaml's own server and provider names
  defp name(name), do: String.to_atom(name)

  defp table!(value, _path) when is_map(value), do: value
  defp table!(nil, _path), do: %{}

  defp table!(_value, []),
    do:
      invalid!(
        ["the file"],
        "is a set of sections: org, tools, defaults, mcp, oauth, vault, ssh, http, " <>
          "channels, notify, cluster, storage"
      )

  defp table!(_value, path), do: invalid!(path, "is a set of keys")

  defp known!(table, keys, path) do
    case Map.keys(table) -- keys do
      [] ->
        :ok

      [key | _] ->
        invalid!(path ++ [key], "is not a setting; expected one of #{Enum.join(keys, ", ")}")
    end
  end

  # The path is built innermost first and turned around only when it is
  # reported.
  defp interpolate(value, path, secret) when is_map(value),
    do: Map.new(value, fn {key, value} -> {key, interpolate(value, [key | path], secret)} end)

  defp interpolate(value, path, secret) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map(fn {value, i} -> interpolate(value, ["#{i}" | path], secret) end)
  end

  defp interpolate(value, path, secret) when is_binary(value) do
    Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/, value, fn _match, name ->
      System.get_env(name) || secret.(name, Enum.reverse(path))
    end)
  end

  defp interpolate(value, _path, _secret), do: value

  defp secret(name, path, nil, env),
    do: invalid!(path, "names ${#{name}}, which is not set; #{set(name, env)}")

  defp secret(name, [section | _rest] = path, vault, env) do
    cond do
      reason = @environment_only[section] ->
        invalid!(path, "names ${#{name}}, which is not set; #{reason}, so #{set(name, env)}")

      value = vault.(name) ->
        value

      true ->
        invalid!(
          path,
          "names ${#{name}}, which neither the environment nor the vault sets; " <>
            "wardrik vault put #{name} seals it, or #{set(name, env)}"
        )
    end
  end

  # Where to set a variable that is not set: the env file, where there is one.
  defp set(name, env) do
    if File.exists?(env),
      do: "add #{name}=... to #{env}, or set it in the environment wardrik runs in",
      else: "set it in the environment wardrik runs in, or create #{env} with a line #{name}=..."
  end

  defp only(document, nil), do: document
  defp only(document, sections), do: Map.take(document, sections)

  defp invalid!(path, message), do: throw({:invalid, path, message})
end
