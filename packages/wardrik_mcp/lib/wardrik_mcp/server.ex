defmodule WardrikMCP.Server do
  @moduledoc """
  One MCP server as Wardrik is configured to reach it.

      WardrikMCP.Server.new(Wardrik.Servers.Key.deployment("github"),
        transport: {:stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-github"]},
        only: ~w(search_issues create_issue)
      )

  | Field | Default | What it decides |
  | --- | --- | --- |
  | `:key` | required | whose server this is and what it is called among theirs, a `Wardrik.Servers.Key`; its name is the prefix on its tool names |
  | `:transport` | required | `{:stdio, opts}` or `{:streamable_http, opts}`, as `Anubis.Client` takes them |
  | `:prefix` | the key's name | what every tool name from this server starts with, which may not hold `__` |
  | `:serves` | every agent | the prefixes whose agents may call its tools, as `Wardrik.AgentID.Prefix`es |
  | `:only` | every tool | the remote names to take |
  | `:except` | none | the remote names to leave |
  | `:gated` | every tool the server does not mark `readOnlyHint` | the remote names whose calls wait on a person unless a hook allows them by name, a name ending in `*` naming every tool it begins, `true` for all of them, or `false` for none; see `c:Wardrik.Tool.gated?/1` |
  | `:trusted` | `false` | whether what its tools answer is the deployment's own; otherwise it is labelled `"outside"`, see `Wardrik.Tool.Annotations` |
  | `:timeout` | 60s | how long one call to this server may take |
  | `:max_result_bytes` | 128 KB | how much of a result reaches the model |
  | `:credential` | none | the name of the credential each call is made with, resolved for the call |
  | `:credential_header` | `authorization` | the header a resolved credential is sent in |
  | `:credential_env` | none | the variable a resolved credential is given to a command in |
  | `:store` | none | the `WardrikStore` the tools a user's connection listed are kept in, for every node; see `WardrikMCP.Listing` |
  | `:stderr` | `:inherit` | where a command's own output goes: `:inherit`, `:discard`, or `{:file, path}` |
  | `:first_retry` | 1s | how long a connection that could not list the server's tools waits before asking again the first time, doubling each time after |
  | `:refresh_after` | 250ms | how long a connection waits after the server says its tools changed before listing them, so a burst of changes costs one listing |
  | `:idle_after` | `:infinity` | how long the server's own connection, the one that lists its tools, runs with no call through it before it stops; one that stops keeps the tools it listed in `:store`, and starts again when an agent's tools are next built |
  | `:inherit_env` | `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LOGNAME`, `PATH`, `SHELL`, `TERM`, `TMPDIR`, `USER` | the variables a command keeps from the node's own environment, or `:all` |

  An HTTP transport takes the server's whole URL as `:base_url`: the path is
  split off into `:mcp_path` rather than appended to, so the URL a vendor
  publishes works as written.

  A credential fixed for the whole deployment is part of the transport: `:env`
  for a command, `:headers` for HTTP.

      transport: {:streamable_http,
        base_url: "https://mcp.example.com",
        headers: %{"authorization" => "Bearer " <> token}}

  ## What a command sees of the node's environment

  A command keeps only the `:inherit_env` variables of the node's own
  environment, beside the `:env` its transport sets and its `:credential_env`.
  The rest are unset before it starts, so a cookie, a vault key or a provider
  key the node was started with reaches no server that was not given it.

  On a node started from a release, `PATH` is kept without the release's own
  directories, which the release puts first: a command that runs `erl` or
  `elixir` gets the one the host installed, not the release's.

  ## What a command writes to stderr

  A command inherits the terminal Wardrik was started in, so a server that prints
  notices writes them over whatever is drawn there. `:stderr` sends them
  somewhere else instead:

      stderr: {:file, "/tmp/wardrik-mcp.log"}

  Only stdout carries the protocol, so nothing here touches it.

  ## Which tools ask

  A tool the server does not mark `readOnlyHint` may change something, so its
  calls wait on a person unless a hook allows them by name, as an MCP client
  asks before such a tool. The hint is taken from any server configured here:
  one that would lie about its tools could do as much harm on any call.
  `:gated` decides instead: a list of the tools that ask, `true` for all of
  them, or `false` for none.

  ## A server each user reaches as themselves

  `:credential` names a credential to resolve for each call instead, through
  the call's resolver, such as `WardrikVault`:

      credential: "github"

  The answer may be the call's user's, its org's or the deployment's, and
  calls run over a connection of its owner's own: a user's within their org,
  an org's, or the deployment's. A user who has not authorized yet parks the
  call rather than failing it. The tools a server offers are listed once over
  the deployment's own connection and shared: the MCP specification has list
  results not varying per connection.
  """

  @enforce_keys [:key, :transport]
  defstruct [
    :key,
    :transport,
    :prefix,
    :only,
    :credential,
    :credential_env,
    except: [],
    serves: [Wardrik.AgentID.Prefix.all()],
    gated: nil,
    trusted: false,
    store: WardrikStore.new(adapter: WardrikStore.None),
    stderr: :inherit,
    inherit_env: ~w(HOME LANG LC_ALL LC_CTYPE LOGNAME PATH SHELL TERM TMPDIR USER),
    credential_header: "authorization",
    credential_scheme: "Bearer",
    timeout: :timer.seconds(60),
    max_result_bytes: 128 * 1024,
    first_retry: :timer.seconds(1),
    refresh_after: 250,
    idle_after: :infinity
  ]

  @typedoc "A transport as `Anubis.Client` takes it."
  @type transport() :: {:stdio | :streamable_http | :websocket, keyword()}

  @typedoc "A configured server."
  @type t() :: %__MODULE__{
          key: Wardrik.Servers.Key.t(),
          transport: transport(),
          prefix: String.t(),
          only: [String.t()] | nil,
          except: [String.t()],
          serves: [Wardrik.AgentID.Prefix.t()],
          gated: [String.t()] | boolean() | nil,
          trusted: boolean(),
          credential: Wardrik.Credential.ref() | nil,
          credential_header: String.t(),
          credential_scheme: String.t(),
          credential_env: String.t() | nil,
          store: WardrikStore.t(),
          stderr: :inherit | :discard | {:file, Path.t()},
          inherit_env: [String.t()] | :all,
          timeout: timeout(),
          max_result_bytes: pos_integer() | :infinity,
          first_retry: pos_integer(),
          refresh_after: non_neg_integer(),
          idle_after: timeout()
        }

  @doc """
  Builds a server from its key and options.

  Raises on a missing or unknown transport, and on an option this struct does
  not have.
  """
  @spec new(Wardrik.Servers.Key.t(), keyword()) :: t()
  def new(%Wardrik.Servers.Key{} = key, opts) when is_list(opts) do
    server = struct!(__MODULE__, Keyword.put(opts, :key, key))

    %{server | prefix: server.prefix || key.name}
    |> validate_prefix!()
    |> validate_transport!()
    |> split_url()
    |> scrub_env()
    |> redirect_stderr()
  end

  @doc "Whether this server is reached over HTTP, and so needs a connection pool."
  @spec http?(t()) :: boolean()
  def http?(%__MODULE__{transport: {layer, _opts}}), do: layer in [:streamable_http, :websocket]

  @doc "Whether calls reach this server with a credential resolved for each, over a connection of its owner's."
  @spec per_user?(t()) :: boolean()
  def per_user?(%__MODULE__{credential: credential}), do: not is_nil(credential)

  @doc """
  The transport this server uses, carrying `credential`.

  An HTTP transport takes a header, a command takes an environment variable,
  and a server with `:credential_env` unset cannot carry one to a command.
  """
  @spec with_credential(t(), Wardrik.Credential.t()) :: {:ok, transport()} | {:error, String.t()}
  def with_credential(%__MODULE__{transport: {:stdio, _opts}, credential_env: nil} = server, _c) do
    {:error, "#{server.key} runs a command and sets no :credential_env to give a token to"}
  end

  def with_credential(%__MODULE__{transport: {:stdio, opts}} = server, credential) do
    env = opts |> Keyword.get(:env) |> Kernel.||(%{})
    value = Wardrik.Credential.reveal(credential)

    {:ok, {:stdio, Keyword.put(opts, :env, Map.put(env, server.credential_env, value))}}
  end

  def with_credential(%__MODULE__{transport: {layer, opts}} = server, credential) do
    headers = opts |> Keyword.get(:headers) |> Kernel.||(%{})
    value = String.trim("#{server.credential_scheme} #{Wardrik.Credential.reveal(credential)}")

    {:ok, {layer, Keyword.put(opts, :headers, Map.put(headers, server.credential_header, value))}}
  end

  @doc "Whether the agent `id` may call this server's tools: one of `:serves` covers it."
  @spec serves?(t(), Wardrik.AgentID.t()) :: boolean()
  def serves?(%__MODULE__{serves: serves}, %Wardrik.AgentID{} = id),
    do: Enum.any?(serves, &Wardrik.AgentID.Prefix.covers?(&1, id))

  @doc "Whether a remote tool name is one this server offers to an agent."
  @spec offers?(t(), String.t()) :: boolean()
  def offers?(%__MODULE__{} = server, name) do
    (is_nil(server.only) or name in server.only) and name not in server.except
  end

  @doc """
  Whether calls to a remote tool wait on a person unless a hook allows them
  by name, with `read_only?` whether the server marks it `readOnlyHint`.
  """
  @spec gated?(t(), String.t(), boolean()) :: boolean()
  def gated?(%__MODULE__{gated: nil}, _name, read_only?), do: not read_only?
  def gated?(%__MODULE__{gated: gated}, _name, _read_only?) when is_boolean(gated), do: gated

  def gated?(%__MODULE__{gated: gated}, name, _read_only?) when is_list(gated) do
    Enum.any?(gated, fn gate ->
      if String.ends_with?(gate, "*"),
        do: String.starts_with?(name, String.trim_trailing(gate, "*")),
        else: name == gate
    end)
  end

  @doc """
  What a remote tool is called here.

  The prefix and the remote name, joined by `__`, with anything a tool name may
  not hold replaced by `_` and the whole truncated to the 64 characters a
  provider accepts.
  """
  @spec local_name(t(), String.t()) :: String.t()
  def local_name(%__MODULE__{prefix: prefix}, name) do
    [prefix, name]
    |> Enum.map_join("__", &tool_name_part/1)
    |> String.slice(0, 64)
  end

  defp tool_name_part(part), do: String.replace(part, ~r/[^a-zA-Z0-9_-]/, "_")

  # `__` is what separates the prefix from each tool's own name.
  defp validate_prefix!(%__MODULE__{prefix: prefix} = server) do
    if String.contains?(tool_name_part(prefix), "__") do
      raise ArgumentError,
            "a server's prefix may not hold \"__\", which comes between it and each tool's " <>
              "name, got: #{inspect(prefix)}"
    end

    server
  end

  defp validate_transport!(%__MODULE__{transport: {layer, opts}} = server)
       when layer in [:stdio, :streamable_http, :websocket] and is_list(opts) do
    server
  end

  defp validate_transport!(%__MODULE__{transport: transport}) do
    raise ArgumentError,
          "expected :transport as {:stdio | :streamable_http | :websocket, opts}, got: " <>
            inspect(transport)
  end

  # The transport appends `:mcp_path` to `:base_url`, so a URL given whole
  # would ask for /mcp/mcp. The path it carries is the path.
  defp split_url(%__MODULE__{transport: {layer, opts}} = server)
       when layer in [:streamable_http, :websocket] do
    uri = opts |> Keyword.fetch!(:base_url) |> URI.parse()
    path = uri.path || ""

    if path in ["", "/"] or Keyword.has_key?(opts, :mcp_path) do
      server
    else
      base = %{uri | path: nil} |> URI.to_string()

      %{
        server
        | transport: {layer, opts |> Keyword.put(:base_url, base) |> Keyword.put(:mcp_path, path)}
      }
    end
  end

  defp split_url(%__MODULE__{} = server), do: server

  # `env -u` names the variables to drop rather than restating the ones to
  # keep, so no value lands in the command's arguments, where `ps` would show
  # it. What the transport sets and the credential variable are kept: the port
  # sets them on this process before `env` runs.
  defp scrub_env(%__MODULE__{inherit_env: :all} = server), do: server

  defp scrub_env(%__MODULE__{transport: {:stdio, opts}} = server) do
    case System.find_executable("env") do
      nil ->
        server

      env ->
        given = opts[:env] || %{}
        keep = server.inherit_env ++ Map.keys(given) ++ List.wrap(server.credential_env)
        unset = for {name, _value} <- System.get_env(), name not in keep, do: ["-u", name]
        args = List.flatten(unset) ++ [opts[:command] | opts[:args] || []]

        opts =
          opts
          |> Keyword.put(:command, env)
          |> Keyword.put(:args, args)
          |> Keyword.put(:env, host_path(given, "PATH" in server.inherit_env))

        %{server | transport: {:stdio, opts}}
    end
  end

  defp scrub_env(%__MODULE__{} = server), do: server

  defp host_path(%{"PATH" => _path} = given, _kept), do: given
  defp host_path(given, false), do: given

  defp host_path(given, true) do
    with path when is_binary(path) <- System.get_env("PATH"),
         release when is_binary(release) <- System.get_env("RELEASE_ROOT") do
      root = Path.expand(release)

      host =
        path
        |> String.split(":")
        |> Enum.reject(
          &(Path.expand(&1) == root or String.starts_with?(Path.expand(&1), root <> "/"))
        )
        |> Enum.join(":")

      Map.put(given, "PATH", host)
    else
      nil -> given
    end
  end

  # The command runs under a shell so its stderr can be pointed away from the
  # terminal Wardrik was started in. `exec` keeps it the same process, so the port
  # still watches the server rather than the shell that started it.
  defp redirect_stderr(%__MODULE__{stderr: :inherit} = server), do: server

  defp redirect_stderr(%__MODULE__{transport: {:stdio, opts}} = server) do
    case System.find_executable("sh") do
      nil ->
        server

      shell ->
        command = Enum.map_join([opts[:command] | opts[:args] || []], " ", &quote_argument/1)
        script = "exec #{command} 2#{where(server.stderr)}"

        %{
          server
          | transport:
              {:stdio, opts |> Keyword.put(:command, shell) |> Keyword.put(:args, ["-c", script])}
        }
    end
  end

  defp redirect_stderr(%__MODULE__{} = server), do: server

  defp where(:discard), do: ">/dev/null"
  defp where({:file, path}), do: ">>" <> quote_argument(path)

  defp quote_argument(argument) do
    "'" <> String.replace(to_string(argument), "'", "'\\''") <> "'"
  end
end
