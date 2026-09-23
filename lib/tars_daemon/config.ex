defmodule TarsDaemon.Config do
  @moduledoc """
  Where the daemon keeps things, and what `config.yaml` configures.

  The daemon follows the XDG base directories, so what a person writes stays
  apart from what the daemon writes:

  | Directory | Default | What it holds |
  | --- | --- | --- |
  | `TARS_CONFIG_DIR` | `$XDG_CONFIG_HOME/tars`, `~/.config/tars` | `config.yaml`, and `agents/`; see `TarsDaemon.AgentFile` |
  | `TARS_DATA_DIR` | `$XDG_DATA_HOME/tars/store`, `~/.local/share/tars/store` | the store |
  | `TARS_COOKIE_FILE` | `$XDG_DATA_HOME/tars/cookie`, `~/.local/share/tars/cookie` | the node's distribution cookie |
  | `TARS_STATE_DIR` | `$XDG_STATE_HOME/tars`, `~/.local/state/tars` | `log/tars.log`, and `log/mcp.log` for what MCP commands write to stderr |

  ## config.yaml

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
  describes them. `vault` takes `keys`, as `TarsVault` does.

  `read/1` refuses a file with a variable that is not set, a key nothing takes,
  or a server that is neither a command nor a URL, and says where.
  """

  @typedoc "Settings for one package, as `Application.put_env(:tars, package, settings)` takes them."
  @type settings() :: [{module(), keyword()}]

  @transport ~w(command args env cwd url headers)a
  @server @transport ++
            ~w(only except prefix timeout max_result_bytes credential credential_header credential_scheme credential_env)a
  @oauth ~w(client redirect providers)a
  @client ~w(name document_url client_uri logo_uri policy_uri tos_uri redirect_uri)a
  @redirect ~w(uri port open)a
  @provider ~w(resource issuer client_id client_secret redirect_uri scopes)a
  @vault ~w(keys)a

  @settings Map.new(
              @server ++ @oauth ++ @client ++ @redirect ++ @provider ++ @vault,
              &{Atom.to_string(&1), &1}
            )

  @transport_keys Enum.map(@transport, &Atom.to_string/1)
  @server_keys Enum.map(@server, &Atom.to_string/1)
  @oauth_keys Enum.map(@oauth, &Atom.to_string/1)
  @client_keys Enum.map(@client, &Atom.to_string/1)
  @redirect_keys Enum.map(@redirect, &Atom.to_string/1)
  @provider_keys Enum.map(@provider, &Atom.to_string/1)
  @vault_keys Enum.map(@vault, &Atom.to_string/1)
  @credential_kinds %{"user" => :user, "org" => :org, "named" => :named}

  @doc "Where `config.yaml` is read from: `TARS_CONFIG_DIR`, or `tars` under the XDG config home."
  @spec config_dir() :: Path.t()
  def config_dir, do: dir("TARS_CONFIG_DIR", "XDG_CONFIG_HOME", "~/.config")

  @doc "Where logs are written: `TARS_STATE_DIR`, or `tars` under the XDG state home."
  @spec state_dir() :: Path.t()
  def state_dir, do: dir("TARS_STATE_DIR", "XDG_STATE_HOME", "~/.local/state")

  defp dir(own, xdg, default) do
    System.get_env(own) || Path.join(System.get_env(xdg) || Path.expand(default), "tars")
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
      {"mcp", servers} -> {TarsMCP, servers: servers(table!(servers, ["mcp"]))}
      {"oauth", oauth} -> {TarsOAuth, oauth(table!(oauth, ["oauth"]))}
      {"vault", vault} -> {TarsVault, vault(table!(vault, ["vault"]))}
      {section, _value} -> invalid!([section], "is not a section; expected mcp, oauth or vault")
    end)
  end

  # -- mcp -------------------------------------------------------------------

  defp servers(servers) do
    Enum.map(servers, fn {name, server} ->
      path = ["mcp", name]
      server = table!(server, path)
      known!(server, @server_keys, path)

      {name(name),
       [transport: transport(server, path)] ++
         Enum.map(Map.drop(server, @transport_keys), &server_option(&1, path))}
    end)
  end

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
      {name(name), options(provider, @provider_keys, ["oauth", "providers", name])}
    end)
  end

  defp vault(vault), do: options(vault, @vault_keys, ["vault"])

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
  defp table!(_value, []), do: invalid!(["the file"], "is a set of sections: mcp, oauth, vault")
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
