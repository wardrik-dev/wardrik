defmodule TarsDaemon.Config do
  @moduledoc """
  Where the daemon keeps things, and what `config.yaml` configures.

  The daemon follows the XDG base directories, so what a person writes stays
  apart from what the daemon writes:

  | Directory | Default | What it holds |
  | --- | --- | --- |
  | `TARS_CONFIG_DIR` | `$XDG_CONFIG_HOME/tars`, `~/.config/tars` | `config.yaml` or `config.yml`, and `agents/`; see `TarsDaemon.AgentFile` |
  | `TARS_DATA_DIR` | `$XDG_DATA_HOME/tars/store`, `~/.local/share/tars/store` | the store |
  | `TARS_COOKIE_FILE` | `$XDG_DATA_HOME/tars/cookie`, `~/.local/share/tars/cookie` | the node's distribution cookie |
  | `TARS_STATE_DIR` | `$XDG_STATE_HOME/tars`, `~/.local/state/tars` | `log/tars.log`, and `log/mcp.log` for what MCP commands write to stderr |

  ## config.yaml

  The file is `config.yaml`, or `config.yml`; a directory holding both is
  refused, since one of them would go unread.

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
          credential: user:github

      oauth:
        providers:
          github:
            resource: https://api.githubcopilot.com/mcp/
            client_id: ${GITHUB_CLIENT_ID}
            client_secret: ${GITHUB_CLIENT_SECRET}
            scopes: [repo]

      vault:
        keys: ["${TARS_VAULT_KEY}"]

      notify:
        ops:
          slack:
            channel: "#ops"
            token: ${SLACK_BOT_TOKEN}
            app_token: ${SLACK_APP_TOKEN}
            approvers: [U012ABCDEF]
        audit:
          webhook:
            url: https://hooks.example.com/tars
            secret: ${TARS_WEBHOOK_SECRET}

  It is YAML 1.2, the same YAML an agent file's frontmatter is written in.

  `${NAME}` in any string is replaced with that environment variable, so the
  file itself need hold no secret.

  A server with `command` is started as a command, with `args`, `env` and
  `cwd` beside it; one with `url` is reached over HTTP, with `headers`. Either
  takes `only`, `except`, `prefix`, `timeout` in seconds, `max_result_bytes`,
  and `credential` as `user:NAME`, `org:NAME` or `named:NAME` along with
  `credential_header`, `credential_scheme` and `credential_env`. See
  `TarsMCP.Server`.

  `oauth` takes `client`, `redirect` and `providers`, as `TarsOAuth.Config`
  describes them. `vault` takes `keys`, as `TarsVault` does. `ssh` takes
  `port` and `ip`, as `TarsDaemon.SSH` does, and so does `http`, as `TarsHTTP`
  does.

  `cluster` takes `nodes`, or `dns` and `size`, as `TarsDaemon.Cluster`
  describes them, and joins this daemon to others.

  `notify` names targets an agent file's `notify` routes to, each one
  `slack`, with `channel`, `token`, and optionally `app_token` and
  `approvers`, as `TarsNotify.Slack` takes them; or `webhook`, with `url` and
  optionally `secret`, as `TarsNotify.Webhook` takes them.

  `read/1` refuses a file with a variable that is not set, a key nothing takes,
  a server that is neither a command nor a URL, or a server whose name or
  `prefix` holds `__`, and says where.
  """

  alias TarsDaemon.Cluster.DNSPoll
  alias TarsDaemon.Cluster.Epmd
  alias TarsDaemon.Cluster.Topology

  @typedoc "Settings for one package, as `Application.put_env(:tars, package, settings)` takes them."
  @type settings() :: [{module(), keyword()}]

  @transport ~w(command args env cwd url headers)a
  @server @transport ++
            ~w(only except prefix timeout max_result_bytes credential credential_header credential_scheme credential_env)a
  @oauth ~w(client redirect providers)a
  @client ~w(name document_url client_uri logo_uri policy_uri tos_uri redirect_uri)a
  @redirect ~w(uri port open)a
  @provider ~w(resource issuer client_id client_secret redirect_uri scopes flow)a
  @vault ~w(keys)a
  @listener ~w(port ip)a
  @notifiers %{
    "slack" => {TarsNotify.Slack, ~w(channel token app_token approvers), ~w(channel token)},
    "webhook" => {TarsNotify.Webhook, ~w(url secret), ~w(url)}
  }

  @settings Map.new(
              @server ++ @oauth ++ @client ++ @redirect ++ @provider ++ @vault ++ @listener,
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
  @credential_kinds %{"user" => :user, "org" => :org, "named" => :named}

  @doc "Where `config.yaml` is read from: `TARS_CONFIG_DIR`, or `tars` under the XDG config home."
  @spec config_dir() :: Path.t()
  def config_dir, do: dir("TARS_CONFIG_DIR", "XDG_CONFIG_HOME", "~/.config")

  @doc "Where what the daemon makes for itself is kept: `tars` under the XDG data home."
  @spec data_dir() :: Path.t()
  def data_dir, do: dir("TARS_DATA_HOME", "XDG_DATA_HOME", "~/.local/share")

  @doc "Where logs are written: `TARS_STATE_DIR`, or `tars` under the XDG state home."
  @spec state_dir() :: Path.t()
  def state_dir, do: dir("TARS_STATE_DIR", "XDG_STATE_HOME", "~/.local/state")

  defp dir(own, xdg, default) do
    System.get_env(own) || Path.join(System.get_env(xdg) || Path.expand(default), "tars")
  end

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

  @doc "The settings `file` configures, or none where there is no file."
  @spec read(Path.t()) :: {:ok, settings()} | {:error, String.t()}
  def read(file) do
    case File.read(file) do
      {:ok, text} -> decode(text, file)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, "#{file}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Merges each package's settings over what its application environment already holds."
  @spec apply(settings()) :: :ok
  def apply(settings) do
    Enum.each(settings, fn {package, opts} ->
      Application.put_env(
        :tars,
        package,
        Keyword.merge(Application.get_env(:tars, package, []), opts)
      )
    end)
  end

  defp decode(text, file) do
    case YamlElixir.read_from_string(text) do
      {:ok, nil} -> {:ok, []}
      {:ok, document} -> {:ok, document |> table!([]) |> interpolate([]) |> settings()}
      {:error, error} -> {:error, "#{file}: is not YAML: #{Exception.message(error)}"}
    end
  catch
    {:invalid, path, message} -> {:error, "#{file}: #{Enum.join(path, ".")} #{message}"}
  end

  defp settings(document) do
    Enum.map(document, fn
      {"mcp", servers} ->
        {TarsMCP, servers: servers(table!(servers, ["mcp"]))}

      {"oauth", oauth} ->
        {TarsOAuth, oauth(table!(oauth, ["oauth"]))}

      {"vault", vault} ->
        {TarsVault, vault(table!(vault, ["vault"]))}

      {"ssh", ssh} ->
        {TarsDaemon.SSH, listener(ssh, "ssh")}

      {"http", http} ->
        {TarsHTTP, listener(http, "http")}

      {"notify", targets} ->
        {TarsNotify, targets: targets(table!(targets, ["notify"]))}

      {"cluster", cluster} ->
        {TarsDaemon.Cluster, cluster(table!(cluster, ["cluster"]))}

      {section, _value} ->
        invalid!(
          [section],
          "is not a section; expected mcp, oauth, vault, ssh, http, notify or cluster"
        )
    end)
  end

  # -- mcp -------------------------------------------------------------------

  defp servers(servers) do
    Enum.map(servers, fn {name, server} ->
      path = ["mcp", name]
      server = table!(server, path)
      known!(server, @server_keys, path)
      prefix!(Map.get(server, "prefix", name), path)

      {name(name),
       [transport: transport(server, path)] ++
         Enum.map(Map.drop(server, @transport_keys), &server_option(&1, path))}
    end)
  end

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
  defp server_option({key, value}, _path), do: {setting(key), value}

  defp credential(ref, path) when is_binary(ref) do
    with [kind, name] when name != "" <- String.split(ref, ":", parts: 2),
         {:ok, kind} <- Map.fetch(@credential_kinds, kind) do
      {kind, name}
    else
      _other -> invalid!(path ++ ["credential"], "is user:NAME, org:NAME or named:NAME")
    end
  end

  defp credential(_ref, path),
    do: invalid!(path ++ ["credential"], "is user:NAME, org:NAME or named:NAME")

  # -- oauth and vault -------------------------------------------------------

  defp oauth(oauth) do
    known!(oauth, @oauth_keys, ["oauth"])

    Enum.map(oauth, fn
      {"client", client} ->
        {:client, options(client, @client_keys, ["oauth", "client"])}

      {"redirect", redirect} ->
        {:redirect, options(redirect, @redirect_keys, ["oauth", "redirect"])}

      {"providers", providers} ->
        {:providers, providers(table!(providers, ["oauth", "providers"]))}
    end)
  end

  defp providers(providers) do
    Enum.map(providers, fn {name, provider} ->
      path = ["oauth", "providers", name]
      {name(name), provider |> options(@provider_keys, path) |> flow(path)}
    end)
  end

  defp flow(provider, path) do
    case Keyword.fetch(provider, :flow) do
      {:ok, flow} when flow in ["auto", "browser", "device"] ->
        Keyword.put(provider, :flow, TarsOAuth.Provider.flow!(flow))

      {:ok, _flow} ->
        invalid!(path ++ ["flow"], "is auto, browser or device")

      :error ->
        provider
    end
  end

  defp vault(vault), do: options(vault, @vault_keys, ["vault"])

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

  defp targets(targets) do
    Enum.map(targets, fn {name, target} ->
      path = ["notify", name]

      case Map.to_list(table!(target, path)) do
        [{kind, options}] -> {name(name), notifier(kind, options, path ++ [kind])}
        _other -> invalid!(path, "is one of slack or webhook")
      end
    end)
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
        invalid!(Enum.drop(path, -1), "is one of slack or webhook")
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
        do: invalid!(path, "is #{inspect(name)}, which is not a node name such as a or tars@box1")

    case Enum.split_with(names, fn {name, _path} -> String.contains?(name, "@") end) do
      {_full, []} ->
        :ok

      {[], _short} ->
        :ok

      {_full, _short} ->
        invalid!(["cluster", "nodes"], "mixes names on this machine with full names")
    end

    nodes = Enum.map(names, fn {name, _path} -> TarsDaemon.Cluster.node_name(name) end)

    case nodes -- Enum.uniq(nodes) do
      [] ->
        nodes

      [twice | _] ->
        invalid!(["cluster", "nodes"], "names #{TarsDaemon.Cluster.display(twice)} twice")
    end
  end

  defp cluster_nodes(_names),
    do: invalid!(["cluster", "nodes"], "is a list of node names, such as [a, b, c]")

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
        "is a set of sections: mcp, oauth, vault, ssh, http, notify, cluster"
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
  defp interpolate(value, path) when is_map(value),
    do: Map.new(value, fn {key, value} -> {key, interpolate(value, [key | path])} end)

  defp interpolate(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map(fn {value, i} -> interpolate(value, ["#{i}" | path]) end)
  end

  defp interpolate(value, path) when is_binary(value) do
    Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/, value, fn _match, name ->
      System.get_env(name) || invalid!(Enum.reverse(path), "names ${#{name}}, which is not set")
    end)
  end

  defp interpolate(value, _path), do: value

  defp invalid!(path, message), do: throw({:invalid, path, message})
end
