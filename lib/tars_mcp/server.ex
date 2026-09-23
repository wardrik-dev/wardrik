defmodule TarsMCP.Server do
  @moduledoc """
  One MCP server as Tars is configured to reach it.

      TarsMCP.Server.new(:github,
        transport: {:stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-github"]},
        only: ~w(search_issues create_issue)
      )

  | Field | Default | What it decides |
  | --- | --- | --- |
  | `:ref` | required | what this server is called here, and the prefix on its tool names |
  | `:transport` | required | `{:stdio, opts}` or `{:streamable_http, opts}`, as `Anubis.Client` takes them |
  | `:prefix` | the ref | what every tool name from this server starts with |
  | `:only` | every tool | the remote names to take |
  | `:except` | none | the remote names to leave |
  | `:timeout` | 60s | how long one call to this server may take |
  | `:max_result_bytes` | 128 KB | how much of a result reaches the model |
  | `:credential` | none | a `t:Tars.Credential.ref/0` each call is made with |
  | `:credential_header` | `authorization` | the header a resolved credential is sent in |
  | `:credential_env` | none | the variable a resolved credential is given to a command in |
  | `:stderr` | `:inherit` | where a command's own output goes: `:inherit`, `:discard`, or `{:file, path}` |
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

  `PATH` is kept without the directories under the running VM's own root,
  which the VM puts first: a command that runs `erl` or `elixir` gets the one
  the host installed, not this node's.

  ## What a command writes to stderr

  A command inherits the terminal Tars was started in, so a server that prints
  notices writes them over whatever is drawn there. `:stderr` sends them
  somewhere else instead:

      stderr: {:file, "/tmp/tars-mcp.log"}

  Only stdout carries the protocol, so nothing here touches it.

  ## A server each user reaches as themselves

  `:credential` names what to resolve instead, and the answer is different per
  user:

      credential: {:user, "github"}

  Calls then run over a connection of that user's own, and a user who has not
  authorized yet parks the call rather than failing it. The tools a server
  offers are listed once over the deployment's own connection and shared: the
  MCP specification has list results not varying per connection.
  """

  @enforce_keys [:ref, :transport]
  defstruct [
    :ref,
    :transport,
    :prefix,
    :only,
    :credential,
    :credential_env,
    except: [],
    stderr: :inherit,
    inherit_env: ~w(HOME LANG LC_ALL LC_CTYPE LOGNAME PATH SHELL TERM TMPDIR USER),
    credential_header: "authorization",
    credential_scheme: "Bearer",
    timeout: :timer.seconds(60),
    max_result_bytes: 128 * 1024
  ]

  @typedoc "A transport as `Anubis.Client` takes it."
  @type transport() :: {:stdio | :streamable_http | :websocket, keyword()}

  @typedoc "A configured server."
  @type t() :: %__MODULE__{
          ref: atom(),
          transport: transport(),
          prefix: String.t(),
          only: [String.t()] | nil,
          except: [String.t()],
          credential: Tars.Credential.ref() | nil,
          credential_header: String.t(),
          credential_scheme: String.t(),
          credential_env: String.t() | nil,
          stderr: :inherit | :discard | {:file, Path.t()},
          inherit_env: [String.t()] | :all,
          timeout: timeout(),
          max_result_bytes: pos_integer() | :infinity
        }

  @doc """
  Builds a server from its ref and options.

  Raises on a missing or unknown transport, and on an option this struct does
  not have.
  """
  @spec new(atom(), keyword()) :: t()
  def new(ref, opts) when is_atom(ref) and is_list(opts) do
    server = struct!(__MODULE__, Keyword.put(opts, :ref, ref))

    %{server | prefix: server.prefix || to_string(ref)}
    |> validate_transport!()
    |> split_url()
    |> scrub_env()
    |> redirect_stderr()
  end

  @doc "Whether this server is reached over HTTP, and so needs a connection pool."
  @spec http?(t()) :: boolean()
  def http?(%__MODULE__{transport: {layer, _opts}}), do: layer in [:streamable_http, :websocket]

  @doc "Whether each user reaches this server as themselves."
  @spec per_user?(t()) :: boolean()
  def per_user?(%__MODULE__{credential: credential}), do: not is_nil(credential)

  @doc """
  The transport this server uses, carrying `credential`.

  An HTTP transport takes a header, a command takes an environment variable,
  and a server with `:credential_env` unset cannot carry one to a command.
  """
  @spec with_credential(t(), Tars.Credential.t()) :: {:ok, transport()} | {:error, String.t()}
  def with_credential(%__MODULE__{transport: {:stdio, _opts}, credential_env: nil} = server, _c) do
    {:error, "#{server.ref} runs a command and sets no :credential_env to give a token to"}
  end

  def with_credential(%__MODULE__{transport: {:stdio, opts}} = server, credential) do
    env = opts |> Keyword.get(:env) |> Kernel.||(%{})
    value = Tars.Credential.reveal(credential)

    {:ok, {:stdio, Keyword.put(opts, :env, Map.put(env, server.credential_env, value))}}
  end

  def with_credential(%__MODULE__{transport: {layer, opts}} = server, credential) do
    headers = opts |> Keyword.get(:headers) |> Kernel.||(%{})
    value = String.trim("#{server.credential_scheme} #{Tars.Credential.reveal(credential)}")

    {:ok, {layer, Keyword.put(opts, :headers, Map.put(headers, server.credential_header, value))}}
  end

  @doc "Whether a remote tool name is one this server offers to an agent."
  @spec offers?(t(), String.t()) :: boolean()
  def offers?(%__MODULE__{} = server, name) do
    (is_nil(server.only) or name in server.only) and name not in server.except
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
    |> Enum.map_join("__", &String.replace(&1, ~r/[^a-zA-Z0-9_-]/, "_"))
    |> String.slice(0, 64)
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
    case System.get_env("PATH") do
      nil ->
        given

      path ->
        root = to_string(:code.root_dir())

        host =
          path
          |> String.split(":")
          |> Enum.reject(&String.starts_with?(Path.expand(&1), root))
          |> Enum.join(":")

        Map.put(given, "PATH", host)
    end
  end

  # The command runs under a shell so its stderr can be pointed away from the
  # terminal Tars was started in. `exec` keeps it the same process, so the port
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
