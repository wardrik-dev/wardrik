defmodule WardrikDaemon.Config do
  @moduledoc """
  Where the daemon keeps things, and what `config.yaml` configures. The
  [config.yaml](config.md) guide is the file's every key and directory, for
  whoever writes one.

  `read/1` refuses a file with a variable that is not set, a key nothing
  takes, a server that is neither a command nor a URL, a server whose name
  or `prefix` holds `__`, or an org that uses what the file does not define,
  and says where. `boot/1` reads what a release needs before anything
  starts, `storage`, `cluster` and `http`, from the environment alone.
  `org/1`, `orgs/1` and `base_url/1` read those settings.

  ## Where the settings go

  `load/1` reads the file once, as the daemon's tree starts, into a
  `WardrikDaemon.Config`: the directories, and each section by the module it
  is for. The tree hands it to what it starts, and each package is started
  with its section as options: `WardrikMCP.Supervisor` with what `mcp` says,
  `WardrikOAuth` with `oauth`, and so on; `section/2` reads one. A release's
  own configuration may give a module settings of its own under
  `:wardrik_daemon`, which the release reads once as it starts and
  `config.yaml` is merged over:

  ```elixir
  config :wardrik_daemon, WardrikVault, shared: ["SEARCH_API_KEY"]
  ```
  """

  alias Wardrik.AgentID.Prefix
  alias WardrikDaemon.Cluster.DNSPoll
  alias WardrikDaemon.Cluster.Epmd
  alias WardrikDaemon.Cluster.Topology

  @typedoc "Settings by the module they are for, which the daemon starts with them."
  @type settings() :: [{module(), keyword()}]

  @enforce_keys [:config_dir, :data_dir, :state_dir]
  defstruct [
    :config_dir,
    :data_dir,
    :state_dir,
    sections: [],
    adapters: %{},
    triggers: %WardrikTrigger.Offered{}
  ]

  @typedoc """
  What the daemon runs with: where it reads and writes, and what
  `config.yaml` and the release say of each module.
  """
  @type t() :: %__MODULE__{
          config_dir: Path.t(),
          data_dir: Path.t(),
          state_dir: Path.t(),
          sections: settings(),
          adapters: %{String.t() => module()},
          triggers: WardrikTrigger.Offered.t()
        }

  @transport ~w(command args env cwd url headers)a
  @server @transport ++
            ~w(only except prefix timeout max_result_bytes gated trusted credential credential_header credential_scheme credential_env)a
  @oauth ~w(client redirect providers)a
  @client ~w(name document_url client_uri logo_uri policy_uri tos_uri)a
  @redirect ~w(url ip port open)a
  @provider ~w(resource issuer client_id client_secret scopes authorization_params flow)a
  @vault ~w(keys shared)a
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

  @target "is a webhook, or a channel and a room in it"

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

  # What an org in `orgs` may use, by the section that defines it.
  @uses ~w(mcp channels notify)

  @doc """
  A config with the directories `opts` name, each the environment's where
  left out, and `:sections`, none by default. `:adapters` are the channel
  adapters a `channels` type names, and `:triggers` the sources and
  verifiers a trigger names, as the release found them registered as it
  started; see `WardrikChannel.discover/0` and `WardrikTrigger.Offered`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      config_dir: Keyword.get_lazy(opts, :config_dir, &config_dir/0),
      data_dir: Keyword.get_lazy(opts, :data_dir, &data_dir/0),
      state_dir: Keyword.get_lazy(opts, :state_dir, &state_dir/0),
      sections: Keyword.get(opts, :sections, []),
      adapters: Keyword.get(opts, :adapters, %{}),
      triggers: Keyword.get(opts, :triggers, %WardrikTrigger.Offered{})
    }
  end

  @doc "The deployment's org, as `config.yaml` names it, or `#{@org}` where it names none."
  @spec org(t()) :: String.t()
  def org(%__MODULE__{} = config), do: config |> section(WardrikDaemon) |> Keyword.get(:org, @org)

  @doc """
  The orgs the deployment declares: its own, then each `orgs` names. An
  agent, a secret or a token in any other is refused.
  """
  @spec orgs(t()) :: [String.t()]
  def orgs(%__MODULE__{} = config),
    do: config |> section(WardrikDaemon) |> Keyword.get_lazy(:orgs, fn -> [org(config)] end)

  @doc """
  The policy of `policies/` each org's agents are held to, ahead of their
  own, by org, with `*`'s holding every org's.
  """
  @spec ceilings(t()) :: %{String.t() => String.t()}
  def ceilings(%__MODULE__{} = config),
    do: config |> section(WardrikDaemon) |> Keyword.get(:ceilings, %{})

  @doc "Whether `org` is one `config` declares, or why not, with the nearest that is."
  @spec declared(t(), String.t()) :: :ok | {:error, String.t()}
  def declared(%__MODULE__{} = config, org) do
    orgs = orgs(config)
    if org in orgs, do: :ok, else: {:error, undeclared(org, orgs)}
  end

  @doc """
  The deployment's address, as `config.yaml`'s `base_url` names it, or where
  it names none, the HTTP API on this machine's loopback.
  """
  @spec base_url(t()) :: String.t()
  def base_url(%__MODULE__{} = config) do
    Keyword.get_lazy(section(config, WardrikDaemon), :base_url, fn ->
      "http://127.0.0.1:#{Keyword.get(section(config, WardrikHTTP), :port, 4747)}"
    end)
  end

  @doc """
  What `config` says of `module`: what `config.yaml` says of it, merged over
  what the release's configuration gives it. `[]` where neither says
  anything.
  """
  @spec section(t(), module()) :: keyword()
  def section(%__MODULE__{sections: sections}, module), do: Keyword.get(sections, module, [])

  @doc """
  Reads `config.yaml` from the config directory into a config, over the
  release's own settings, `:base`.

  The vault's keys come first, from `vault.keys`, the release's, or the key
  file in the data home, so the rest of the file can read from the vault in
  `:store` what the environment does not set; the keys are kept in the
  config's `WardrikVault` section, as the vault is made from it.
  `:config_dir`, `:data_dir` and `:state_dir` are as `new/1` takes them.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(opts) do
    store = Keyword.fetch!(opts, :store)
    base = Keyword.get(opts, :base, [])
    config = new(opts)

    with {:ok, file} <- file(config.config_dir),
         {:ok, early} <- read(file, only: ["vault"]),
         vault = early_vault(store, merge(base, early), config.data_dir),
         {:ok, read} <-
           read(file, vault: &WardrikDaemon.Secrets.named(vault, &1), adapters: config.adapters) do
      sections =
        base
        |> merge(read)
        |> Keyword.update(WardrikVault, [keys: vault.keys], &Keyword.put(&1, :keys, vault.keys))

      {:ok, %{config | sections: sections}}
    end
  end

  # The vault the rest of the file reads from: no grants, as it reads only
  # the deployment's secrets.
  defp early_vault(store, sections, data_dir) do
    settings = Keyword.get(sections, WardrikVault, [])

    keys =
      case Keyword.get(settings, :keys, []) do
        [] -> WardrikDaemon.VaultKey.keys(data_dir)
        keys -> keys
      end

    WardrikVault.new(
      store: store,
      keys: keys,
      shared: Keyword.get(settings, :shared, [])
    )
  end

  @doc "Each module's settings in `over`, merged over its settings in `base`."
  @spec merge(settings(), settings()) :: settings()
  def merge(base, over) do
    Enum.reduce(over, base, fn {module, opts}, acc ->
      Keyword.update(acc, module, opts, &Keyword.merge(&1, opts))
    end)
  end

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
  `:adapters` are the channel adapters a channel's `type` may name.

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
  What a release reads as it boots, before anything starts: the store
  `storage` names, the cluster `cluster` describes, and the HTTP API's `http`,
  for what the release starts before the daemon reads the rest. A store kept on the nodes,
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

  defp decode(text, file, opts) do
    case YamlElixir.read_from_string(text) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, document} ->
        document = document |> table!([]) |> only(opts[:only])
        env = env_file(Path.dirname(file))
        secret = &secret(&1, &2, opts[:vault], env)
        {:ok, document |> interpolate([], secret) |> sections(Keyword.get(opts, :adapters, %{}))}

      {:error, error} ->
        {:error, "#{file}: is not YAML: #{Exception.message(error)}"}
    end
  catch
    {:invalid, path, message} -> {:error, "#{file}: #{Enum.join(path, ".")} #{message}"}
  end

  defp sections(document, adapters) when is_map(adapters) do
    {org, document} = Map.pop(document, "org")
    {base_url, document} = Map.pop(document, "base_url")
    {uses, document} = Map.pop(document, "orgs")
    org = org!(org)
    base_url = addressed_at(base_url)
    uses = uses(uses, document)
    orgs = Enum.uniq([org | Enum.sort(Map.keys(uses) -- ["*"])])

    [
      {WardrikDaemon, [org: org, orgs: orgs, ceilings: ceilings_of(uses)] ++ base_url}
      | document
        |> sections({org, uses}, orgs, adapters)
        |> through_channels()
        |> addressed(base_url)
    ]
  end

  defp addressed_at(nil), do: []
  defp addressed_at(url), do: [base_url: redirect_url!(url, ["base_url"])]

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

  defp sections(document, owners, orgs, adapters) do
    Enum.map(document, fn
      {"defaults", defaults} ->
        {WardrikDaemon.Agents, defaults: defaults(defaults)}

      {"tools", tools} ->
        {WardrikDaemon.AgentFile, tool_prices: prices(table!(tools, ["tools"]))}

      {"mcp", servers} ->
        {WardrikMCP, servers: servers(table!(servers, ["mcp"]), owners)}

      {"oauth", oauth} ->
        {WardrikOAuth, oauth(table!(oauth, ["oauth"]))}

      {"vault", vault} ->
        {WardrikVault, vault(table!(vault, ["vault"]))}

      {"ssh", ssh} ->
        {WardrikDaemon.SSH, listener(ssh, "ssh")}

      {"http", http} ->
        {WardrikHTTP, http(http)}

      {"notify", targets} ->
        {WardrikNotify, targets: targets(table!(targets, ["notify"]), owners)}

      {"channels", channels} ->
        {WardrikChannel, channels(table!(channels, ["channels"]), owners, adapters)}

      {"cluster", cluster} ->
        {WardrikDaemon.Cluster, cluster(table!(cluster, ["cluster"]))}

      {"storage", storage} ->
        {WardrikStore, storage(table!(storage, ["storage"]))}

      {"workspace", workspace} ->
        {WardrikWorkspace, workspace(table!(workspace, ["workspace"]), orgs)}

      {section, _value} ->
        invalid!(
          [section],
          "is not a section; expected org, orgs, tools, defaults, mcp, oauth, vault, ssh, http, " <>
            "channels, notify, workspace, cluster or storage"
        )
    end)
  end

  # -- workspace -------------------------------------------------------------

  # The trees agents beyond their owners may mount, and who.
  defp workspace(workspace, orgs) do
    known!(workspace, ["shared"], ["workspace"])

    shared =
      for {tree, who} <- table!(Map.get(workspace, "shared"), ["workspace", "shared"]) do
        path = ["workspace", "shared", tree]
        who = table!(who, path)
        known!(who, ["read", "write"], path)

        case WardrikWorkspace.Share.new(tree,
               read: Map.get(who, "read", []),
               write: Map.get(who, "write", [])
             ) do
          {:ok, share} -> declared!(share, orgs, path)
          {:error, message} -> invalid!(path, "does not read: " <> message)
        end
      end

    [shared: shared]
  end

  defp declared!(share, orgs, path) do
    for prefix <- share.read ++ share.write,
        org = Prefix.org(prefix),
        org not in [nil | orgs],
        do: invalid!(path, "names " <> undeclared(org, orgs))

    share
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

  # What each org `orgs` names uses, by section, with `*` for what every org
  # does. Each name must be one the section defines.
  defp uses(nil, _document), do: %{}

  defp uses(orgs, document) do
    Map.new(table!(orgs, ["orgs"]), fn {owner, used} ->
      path = ["orgs", owner]

      unless owner == "*" or Wardrik.AgentID.segment?(owner),
        do: invalid!(path, "is not an org, or * for every org; #{@segment}")

      {ceiling, used} = Map.pop(table!(used, path), "ceiling")
      known!(used, ["ceiling" | @uses], path)

      {owner,
       used
       |> Map.new(fn {section, names} -> {section, used!(names, section, document, path)} end)
       |> Map.put("ceiling", ceiling!(ceiling, path ++ ["ceiling"]))}
    end)
  end

  defp ceiling!(nil, _path), do: nil
  defp ceiling!(name, _path) when is_binary(name) and name != "", do: name
  defp ceiling!(_name, path), do: invalid!(path, "is the name of a policy in policies/")

  # The ceiling policy each org is held to, `*`'s holding every org.
  defp ceilings_of(uses) do
    for {owner, %{"ceiling" => name}} <- uses, name != nil, into: %{}, do: {owner, name}
  end

  defp used!(names, section, document, path) do
    path = path ++ [section]

    unless is_list(names) and Enum.all?(names, &is_binary/1),
      do: invalid!(path, "is a list of names #{section} defines")

    defined = document |> Map.get(section) |> table!([section]) |> Map.keys()

    for name <- names, name not in defined do
      invalid!(path, "names #{name}, which #{section} does not define#{guess(name, defined)}")
    end

    names
  end

  # The orgs whose agents reach a server or a channel, or hear from a
  # notify target: those whose `orgs` entry lists it, every org where `*`'s
  # does, and the deployment's own where none does.
  defp owners(section, name, {org, uses}) do
    case for({owner, used} <- uses, name in Map.get(used, section, []), do: owner) do
      [] -> [org]
      owners -> if "*" in owners, do: :all, else: Enum.sort(owners)
    end
  end

  defp undeclared(org, orgs),
    do: "#{org} is not an org config.yaml declares: #{Enum.join(orgs, ", ")}#{guess(org, orgs)}"

  defp guess(name, names) do
    case Enum.max_by(names, &String.jaro_distance(&1, name), fn -> nil end) do
      nil -> ""
      best -> if String.jaro_distance(best, name) >= 0.8, do: "; did you mean #{best}?", else: ""
    end
  end

  # -- mcp -------------------------------------------------------------------

  defp servers(servers, owners) do
    Enum.map(servers, fn {name, server} ->
      path = ["mcp", name]
      server = table!(server, path)
      known!(server, @server_keys, path)
      prefix!(Map.get(server, "prefix", name), path)

      {name(name),
       [transport: transport(server, path), orgs: owners("mcp", name, owners)] ++
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

  defp vault(vault) do
    vault = options(vault, @vault_keys, ["vault"])

    case Keyword.get(vault, :shared, []) do
      names when is_list(names) ->
        if Enum.all?(names, &is_binary/1),
          do: vault,
          else: invalid!(["vault", "shared"], "is a list of credential names")

      _other ->
        invalid!(["vault", "shared"], "is a list of credential names")
    end
  end

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

  defp targets(targets, owners) do
    Enum.map(targets, fn {name, target} ->
      path = ["notify", name]
      {module, options} = target(table!(target, path), path)
      {name(name), {module, options ++ [orgs: owners("notify", name, owners)]}}
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
  defp channels(channels, owners, adapters) do
    read =
      Enum.map(channels, fn {name, channel} ->
        path = ["channels", name]
        {type, settings} = Map.pop(table!(channel, path), "type")
        {creates, settings} = Map.pop(settings, "create", true)
        {approvers, settings} = Map.pop(settings, "approvers", [])
        approvers = approvers(approvers, path ++ ["approvers"])
        {admins, settings} = Map.pop(settings, "admins", [])
        adapter = adapter!(type, path ++ ["type"], adapters)

        unless is_boolean(creates),
          do: invalid!(path ++ ["create"], "is true or false")

        approvers!(admins, path ++ ["admins"])

        case adapter.config(settings) do
          {:ok, options} ->
            {name(name),
             %{
               channel: {adapter, options},
               orgs: owners("channels", name, owners),
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

  # Who decides in a channel: anyone in it, or the people it names.
  defp approvers("anyone", _path), do: %WardrikDaemon.Approvers.Anyone{}

  defp approvers(names, path) do
    if is_list(names) and Enum.all?(names, &is_binary/1),
      do: %WardrikDaemon.Approvers.Named{names: names},
      else: invalid!(path, "is anyone, or a list of who may answer, as the channel names them")
  end

  defp approvers!(approvers, path) do
    unless is_list(approvers) and Enum.all?(approvers, &is_binary/1),
      do: invalid!(path, "is a list of who may answer, as the channel names them")
  end

  defp adapter!(type, path, adapters) do
    with true <- is_binary(type),
         {:ok, adapter} <- Map.fetch(adapters, type) do
      adapter
    else
      _unknown ->
        case adapters |> Map.keys() |> Enum.sort() do
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
          "channels, notify, workspace, cluster, storage"
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
