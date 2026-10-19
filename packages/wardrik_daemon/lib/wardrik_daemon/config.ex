defmodule WardrikDaemon.Config do
  @moduledoc """
  Where the daemon keeps things, and what `config.yaml` configures. The
  [config.yaml](config.md) guide is the file's every key and directory, for
  whoever writes one.

  `read/1` refuses a file with a variable that is not set, a key nothing
  takes, or an org that uses what the file does not define, and says where.
  `boot/1` reads what a release needs before anything starts, `storage`,
  `cluster` and `http`, from the environment alone. `org/1`, `orgs/1`,
  `base_url/1` and `oauth_settings/1` read those settings.

  ## Where the settings go

  `load/1` reads the file once, as the daemon's tree starts, into a
  `WardrikDaemon.Config`: the directories, and each section by the module it
  is for. A package's section is read by the package, with its `config/1`:
  `mcp` by `WardrikMCP`, `oauth` by `WardrikOAuth`, `notify` by
  `WardrikNotify`, `channels` by `WardrikChannel`, with the channel types
  the daemon holds, and `http` by `WardrikHTTP`; then what `orgs` says each
  org uses is put on each server, channel and target. The daemon attaches
  each package to its host with its section as options; `section/2` reads
  one. A release's own configuration may give a module settings of its own
  under `:wardrik_daemon`, which the release reads once as it starts and
  `config.yaml` is merged over:

  ```elixir
  config :wardrik_daemon, WardrikVault, shared: ["SEARCH_API_KEY"]
  ```
  """

  alias WardrikDaemon.Cluster.DNSPoll
  alias WardrikDaemon.Cluster.Epmd
  alias WardrikDaemon.Cluster.Topology

  @typedoc "Settings by the module they are for, which the daemon starts with them."
  @type settings() :: [{module(), keyword()}]

  # The channel types a channel's `type` names.
  @adapters %{"slack" => WardrikSlack}

  @enforce_keys [:config_dir, :data_dir, :state_dir]
  defstruct [:config_dir, :data_dir, :state_dir, sections: [], adapters: @adapters]

  @typedoc """
  What the daemon runs with: where it reads and writes, and what
  `config.yaml` and the release say of each module.
  """
  @type t() :: %__MODULE__{
          config_dir: Path.t(),
          data_dir: Path.t(),
          state_dir: Path.t(),
          sections: settings(),
          adapters: %{String.t() => module()}
        }

  @vault ~w(keys shared)a
  @listener ~w(port ip)a
  @stores %{
    "postgres" => {WardrikEcto.Store, ~w(url), ~w(url)},
    "s3" =>
      {WardrikS3.Store, ~w(bucket endpoint region prefix access_key_id secret_access_key),
       ~w(bucket endpoint access_key_id secret_access_key)}
  }
  @store_settings ~w(url bucket endpoint region prefix access_key_id secret_access_key)a
  @store_urls %{
    "url" => {~w(postgres postgresql), "a postgres:// URL"},
    "endpoint" => {~w(http https), "an https:// URL"}
  }

  @settings Map.new(@vault ++ @listener ++ @store_settings, &{Atom.to_string(&1), &1})

  @vault_keys Enum.map(@vault, &Atom.to_string/1)
  @listener_keys Enum.map(@listener, &Atom.to_string/1)

  # The sections a read gives no name from the vault, and why.
  @environment_only %{
    "storage" => "storage reads the environment alone, since the vault is kept in the store",
    "cluster" =>
      "cluster reads the environment alone, as the node boots, before the vault can be",
    "http" => "http reads the environment alone, as the node boots, before the vault can be",
    "vault" => "vault reads the environment alone, since the vault cannot unlock itself"
  }
  @org "default"
  @segment "an org holds no / or whitespace, nor *, ? or :, does not begin with @ or _, " <>
             "and is not deployment"

  # What an org in `orgs` may use, by the section that defines it.
  @uses ~w(mcp channels notify)

  @doc """
  A config with the directories `opts` name, each the environment's where
  left out, and `:sections`, none by default. `:adapters` are the channel
  adapters a `channels` type names, the daemon's, `slack`, unless given.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      config_dir: Keyword.get_lazy(opts, :config_dir, &config_dir/0),
      data_dir: Keyword.get_lazy(opts, :data_dir, &data_dir/0),
      state_dir: Keyword.get_lazy(opts, :state_dir, &state_dir/0),
      sections: Keyword.get(opts, :sections, []),
      adapters: Keyword.get(opts, :adapters, @adapters)
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
  The policies of `policies/` each org's agents are held to, ahead of their
  own, by org: `orgs."*".policy`, which holds every org, then
  `orgs.<org>.policy`.
  """
  @spec held(t()) :: %{Wardrik.Resource.t() => [String.t()]}
  def held(%__MODULE__{} = config),
    do: config |> section(WardrikDaemon) |> Keyword.get(:held, %{})

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
  What `WardrikOAuth.new/1` takes of `config`: `oauth`'s client, providers
  and redirect, where a provider sends a browser back to after a sign-in.
  That is `oauth.redirect.url`, or else `/oauth` under `base_url/1`, which
  the HTTP API serves.
  """
  @spec oauth_settings(t()) :: keyword()
  def oauth_settings(%__MODULE__{} = config) do
    settings = Keyword.take(section(config, WardrikOAuth), [:client, :providers, :redirect])
    redirect = Keyword.get(settings, :redirect, [])
    url = Keyword.get_lazy(redirect, :url, fn -> base_url(config) <> "/oauth" end)
    Keyword.put(settings, :redirect, Keyword.put(redirect, :url, url))
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
  `:adapters` are the channel adapters a channel's `type` may name, the
  daemon's unless given.

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

        {:ok,
         document |> interpolate([], secret) |> sections(Keyword.get(opts, :adapters, @adapters))}

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
      {WardrikDaemon, [org: org, orgs: orgs, held: held_of(uses, orgs)] ++ base_url}
      | document
        |> sections({org, uses}, orgs, adapters)
        |> through_channels()
    ]
  end

  defp addressed_at(nil), do: []

  defp addressed_at(url) do
    if is_binary(url) and WardrikOAuth.Callback.redirect?(url),
      do: [base_url: String.trim_trailing(url, "/")],
      else:
        invalid!(
          ["base_url"],
          "is an https:// URL, or http:// on loopback, with no query or fragment"
        )
  end

  # A package's section, as it read it, or where it does not read, under the
  # section's name.
  defp read!(_section, {:ok, settings}), do: settings
  defp read!(section, {:error, path, message}), do: invalid!([section | path], message)

  defp sections(document, owners, orgs, adapters) do
    Enum.map(document, fn
      {"defaults", defaults} ->
        {WardrikDaemon.Agents, defaults: defaults(defaults)}

      {"tools", tools} ->
        {WardrikDaemon.AgentFile, tool_prices: prices(table!(tools, ["tools"]))}

      {"mcp", servers} ->
        {WardrikMCP, "mcp" |> read!(WardrikMCP.config(servers)) |> serving(owners)}

      {"oauth", oauth} ->
        {WardrikOAuth, read!("oauth", WardrikOAuth.config(oauth))}

      {"vault", vault} ->
        {WardrikVault, vault(table!(vault, ["vault"]))}

      {"ssh", ssh} ->
        {WardrikDaemon.SSH, listener(ssh, "ssh")}

      {"http", http} ->
        {WardrikHTTP, read!("http", WardrikHTTP.config(http))}

      {"notify", targets} ->
        {WardrikNotify, "notify" |> read!(WardrikNotify.config(targets)) |> telling(owners)}

      {"channels", channels} ->
        {WardrikChannel,
         "channels" |> read!(WardrikChannel.config(channels, adapters)) |> offering(owners)}

      {"cluster", cluster} ->
        {WardrikDaemon.Cluster, cluster(table!(cluster, ["cluster"]))}

      {"storage", storage} ->
        {WardrikStore, storage(table!(storage, ["storage"]))}

      {"workspace", workspace} ->
        {WardrikWorkspace, workspace(table!(workspace, ["workspace"]), orgs)}

      {"tokens", tokens} ->
        {Wardrik.Tokens, tokens(table!(tokens, ["tokens"]))}

      {section, _value} ->
        invalid!(
          [section],
          "is not a section; expected org, orgs, tools, defaults, mcp, oauth, vault, ssh, http, " <>
            "channels, notify, workspace, tokens, cluster or storage"
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
    for pattern <- share.read ++ share.write,
        [org | _rest] = String.split(to_string(pattern), "/"),
        not String.contains?(org, ["*", "?"]),
        org not in orgs,
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
    if Wardrik.AgentID.org?(org),
      do: org,
      else: invalid!(["org"], "is #{inspect(org)}, which is not an org; #{@segment}")
  end

  # What each org `orgs` names uses, by section, with `*` for what every org
  # does. Each name must be one the section defines.
  defp uses(nil, _document), do: %{}

  defp uses(orgs, document) do
    Map.new(table!(orgs, ["orgs"]), fn {owner, used} ->
      path = ["orgs", owner]

      unless owner == "*" or Wardrik.AgentID.org?(owner),
        do: invalid!(path, "is not an org, or * for every org; #{@segment}")

      {policy, used} = Map.pop(table!(used, path), "policy")
      known!(used, ["policy" | @uses], path)

      {owner,
       used
       |> Map.new(fn {section, names} -> {section, used!(names, section, document, path)} end)
       |> Map.put("policy", policy!(policy, path ++ ["policy"]))}
    end)
  end

  defp policy!(nil, _path), do: nil
  defp policy!(name, _path) when is_binary(name) and name != "", do: name
  defp policy!(_name, path), do: invalid!(path, "is the name of a policy in policies/")

  # The policies each org is held to: `*`'s, which holds every org, then its own.
  defp held_of(uses, orgs) do
    every = List.wrap(get_in(uses, ["*", "policy"]))

    for org <- orgs,
        held = Enum.uniq(every ++ List.wrap(get_in(uses, [org, "policy"]))),
        held != [],
        into: %{},
        do: {Wardrik.Resource.parse!(org), held}
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

  # Each server serves the agents of the orgs `orgs` has use it.
  defp serving(mcp, owners) do
    Keyword.update!(mcp, :servers, fn servers ->
      for {name, server} <- servers,
          do: {name, server ++ [serves: serves(owners("mcp", Atom.to_string(name), owners))]}
    end)
  end

  # The agents a server serves: every org's, or each named org's whole tenant,
  # its users' agents with its own.
  defp serves(:all), do: [Wardrik.Resource.parse!("*")]
  defp serves(orgs), do: Enum.map(orgs, &Wardrik.Resource.parse!(&1 <> "/*"))

  # -- tokens ----------------------------------------------------------------

  # How long the tokens the deployment makes last, by their kind.
  defp tokens(tokens) do
    known!(tokens, ["expires"], ["tokens"])
    path = ["tokens", "expires"]
    expires = table!(tokens["expires"], path)
    known!(expires, ["api", "session"], path)

    [
      expires:
        for {kind, text} <- expires do
          case seconds(text) do
            {:ok, seconds} -> {String.to_existing_atom(kind), seconds}
            :error -> invalid!(path ++ [kind], "is a duration, as 90d, 12h, 30m or 45s")
          end
        end
    ]
  end

  @units %{"d" => 86_400, "h" => 3_600, "m" => 60, "s" => 1}

  @doc "The seconds a duration such as `90d`, `12h`, `30m` or `45s` is, or `:error`."
  @spec seconds(term()) :: {:ok, pos_integer()} | :error
  def seconds(text) when is_binary(text) do
    with [_, n, unit] <- Regex.run(~r/^(\d+)([dhms])$/, String.trim(text)),
         seconds when seconds > 0 <- String.to_integer(n) * Map.fetch!(@units, unit) do
      {:ok, seconds}
    else
      _other -> :error
    end
  end

  def seconds(_text), do: :error

  # -- defaults --------------------------------------------------------------

  # Kept as the file writes them, to be written into an agent file and read
  # as one.
  defp defaults(defaults) do
    defaults = table!(defaults, ["defaults"])

    case Wardrik.Definition.check_defaults(defaults) do
      :ok -> defaults
      {:error, key, message} -> invalid!(["defaults", key], message)
    end
  end

  # -- vault -----------------------------------------------------------------

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

  # Each target tells the agents of the orgs `orgs` has use it.
  defp telling(notify, owners) do
    Keyword.update!(notify, :targets, fn targets ->
      for {name, {module, options}} <- targets,
          do: {name, {module, options ++ [orgs: owners("notify", Atom.to_string(name), owners)]}}
    end)
  end

  # -- channels --------------------------------------------------------------

  # Each channel offers the agents of the orgs `orgs` has use it, and is
  # installed in the workspace its token reaches, for its one org, or for
  # `*`, every org, where it offers several.
  defp offering(channels, owners) do
    {tokens, channels} = Keyword.pop!(channels, :tokens)

    orgs =
      for {name, _channel} <- channels[:channels],
          do: {name, owners("channels", Atom.to_string(name), owners)}

    channels ++
      [
        orgs: orgs,
        installations:
          WardrikChannel.Installations.Config.new(
            for {name, token} <- tokens, do: {name, token, owner(orgs[name])}
          )
      ]
  end

  # Whom a channel's token is installed for: its one org, or every org.
  defp owner([org]), do: Wardrik.Resource.parse!(org)
  defp owner(_orgs), do: Wardrik.Resource.parse!("*")

  # A notify target in a channel posts through it, as `channels` holds it,
  # in the workspace its token reaches.
  defp through_channels(sections) do
    channels = Keyword.get(sections, WardrikChannel, [])

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
    path = ["notify", Atom.to_string(name), "channel"]

    case Enum.find(
           Keyword.get(channels, :channels, []),
           fn {channel, _adapter} -> Atom.to_string(channel) == named end
         ) do
      {_name, channel} ->
        installation = installation!(channels[:installations], named, path)

        {name,
         {WardrikChannel.Notices,
          Keyword.merge(options, channel: channel, installation: installation)}}

      nil ->
        invalid!(path, "is #{named}, which config.yaml's channels does not name")
    end
  end

  defp through(target, _channels), do: target

  defp installation!(installations, channel, path) do
    case WardrikChannel.Installations.fetch(installations, channel, channel) do
      {:ok, installation} -> installation
      :error -> invalid!(path, "is #{channel}, which names no token to post with")
    end
  end

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

  defp setting(key), do: Map.fetch!(@settings, key)

  defp table!(value, _path) when is_map(value), do: value
  defp table!(nil, _path), do: %{}

  defp table!(_value, []),
    do:
      invalid!(
        ["the file"],
        "is a set of sections: org, tools, defaults, mcp, oauth, vault, ssh, http, " <>
          "channels, notify, workspace, tokens, cluster, storage"
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
