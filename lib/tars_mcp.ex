defmodule TarsMCP do
  @moduledoc """
  MCP servers as tools an agent can call.

  A host starts `TarsMCP.Supervisor` with the servers it wants reached, then
  names one in a config the way it names any other tool:

      Tars.LLM.Config.new(tools: [{TarsMCP, :github}])

  The spec is a `Tars.Tool` source: it stands for however many tools that
  server offers, and it travels, so an agent that moves to another node builds
  the same tools again there. A server that is not connected offers none, and
  the config is still valid.

  `{TarsMCP, :*}` names every server connected on the node running the agent,
  rather than one:

      Tars.LLM.Config.new(tools: [{TarsMCP, :*}])

  Both are read again for every turn, so a config outlives the servers it was
  built alongside.

  Tool names are the server's ref, then the remote name: `github__create_issue`.

  ## Configuration

      config :tars, TarsMCP,
        servers: [
          github: [
            transport:
              {:stdio,
               command: "npx",
               args: ["-y", "@modelcontextprotocol/server-github"],
               env: %{"GITHUB_TOKEN" => System.get_env("GITHUB_TOKEN")}},
            only: ~w(search_issues create_issue)
          ],
          linear: [
            transport:
              {:streamable_http,
               base_url: "https://mcp.linear.app/mcp",
               headers: %{"authorization" => "Bearer " <> System.get_env("LINEAR_TOKEN")}}
          ]
        ]

  See `TarsMCP.Server` for every option a server takes. A credential is part of
  the transport: `:env` for a command, `:headers` for HTTP. Tars holds no token
  of its own and runs no OAuth flow; a server that needs one is given a token
  that was minted elsewhere.

  ## Extracting this package

  When MCP moves out into `tars_mcp`, `lib/tars_mcp/` and `test/tars_mcp/` move
  into a project declaring `{:tars, "~> 0.1"}` and `{:anubis_mcp, "~> 2.0"}`,
  and the setting becomes `config :tars_mcp, servers: [...]`.
  """

  @behaviour Tars.Tool

  alias Tars.Credential
  alias Tars.Event
  alias Tars.Scope
  alias Tars.Tool.Result
  alias TarsMCP.Connection
  alias TarsMCP.Offer
  alias TarsMCP.Server

  @doc """
  The tools a server offers, as it last reported them.

  Reads what the connection has already listed, so building a turn's tools
  costs no request. A server that is not connected, or has nothing left after
  `:only` and `:except`, offers none.

  `:*` is every connected server at once, in the order `servers/0` gives them.
  A source named that way is not tied to the servers that existed when it was
  named, so an agent built before a server connected offers its tools on the
  next turn, and one that disconnects takes its own away.
  """
  @impl Tars.Tool
  @spec tools(atom()) :: [ReqLLM.Tool.t()]
  def tools(:*), do: Enum.flat_map(servers(), &Connection.tools/1)
  def tools(ref) when is_atom(ref), do: Connection.tools(ref)

  @doc "How long one MCP call may take, unless the server says otherwise."
  @impl Tars.Tool
  def timeout, do: :timer.seconds(60)

  @doc """
  Calls a tool on a server and reports what it answered.

  What a tool built by `TarsMCP.Tool.build/2` calls; the ref and the remote
  name are the ones it was built with.

  A call made from inside a tool call reports the server's progress as
  `{:tool_progress, call_id, name, progress, total}` on the turn's event
  stream, and is cancelled on the server if this process is stopped before the
  server answers.

  A server with a `:credential` is called over a connection belonging to the
  scope's user. A user who has not authorized it yet gets `{:park, prompt}`,
  which stops the turn until they have. A server that refuses the credential
  it was given is tried once more with a freshly resolved one, which covers a
  token revoked or expired without warning.
  """
  @spec call(atom(), String.t(), map()) :: Result.t() | {:park, String.t()}
  def call(ref, name, params), do: call(ref, name, params, :may_retry)

  defp call(ref, name, params, retry) do
    with %Offer{server: server} <- Connection.offer(ref),
         {:ok, principal} <- connected(server) do
      :ok = Connection.watch(ref, principal)

      answer =
        ref
        |> Connection.client(principal)
        |> request(server, name, arguments(params))

      if retry == :may_retry and refused?(answer) and Server.per_user?(server) do
        Connection.close(ref, principal)
        call(ref, name, params, :tried)
      else
        TarsMCP.Tool.answer(answer, server)
      end
    else
      nil -> Result.error(:no_such_server, "no MCP server is connected as #{inspect(ref)}")
      {:park, prompt} -> {:park, prompt}
      {:error, reason} -> Result.error(:not_authorized, reason)
    end
  end

  # A server saying the credential is no good, however it says it: an HTTP 401
  # or 403 from the transport, or a protocol error carrying one.
  defp refused?({:error, %Anubis.MCP.Error{} = error}) do
    status(error.data) in [401, 403] or status(error.data[:original_reason]) in [401, 403]
  end

  defp refused?(_answer), do: false

  defp status(%{status: status}), do: status
  defp status(%{"status" => status}), do: status
  defp status({:http_error, status, _body}), do: status
  defp status(_other), do: nil

  @doc """
  Authorizes the calling user for a server, or says they already are.

  What the tool `TarsMCP.Tool.connect/1` builds calls. Parks on the link where
  the user has not authorized yet, and lists the server's real tools in place
  of this one once they have.
  """
  @spec authorize(atom(), map()) :: Result.t() | {:park, String.t()}
  def authorize(ref, _params) do
    with %Offer{server: server} <- Connection.offer(ref),
         {:ok, _principal} <- connected(server) do
      Result.ok(%{"connected" => true, "server" => to_string(ref)})
    else
      nil -> Result.error(:no_such_server, "no MCP server is connected as #{inspect(ref)}")
      {:park, prompt} -> {:park, prompt}
      {:error, reason} -> Result.error(:not_authorized, reason)
    end
  end

  @doc "Connects to a server that was not in the configuration."
  @spec connect(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(ref, opts) when is_atom(ref) and is_list(opts) do
    TarsMCP.Supervisor.connect(Server.new(ref, opts))
  end

  @doc "Stops a connection and drops the tools it was offering."
  @spec disconnect(atom()) :: :ok | {:error, :not_found}
  def disconnect(ref) when is_atom(ref), do: TarsMCP.Supervisor.disconnect(ref)

  @doc "The refs of every server currently connected."
  @spec servers() :: [atom()]
  def servers, do: Connection.refs()

  defp request(client, server, name, arguments) do
  @doc "Whether this deployment configured any server. See `TarsMCP.Config`."
  @spec configured?() :: boolean()
  def configured?, do: TarsMCP.Config.configured?()

    opts = [timeout: server.timeout] ++ reporting(server, name)

    Anubis.Client.call_tool(client, name, arguments, opts)
  catch
    :exit, {:noproc, _call} ->
      {:error, Anubis.MCP.Error.transport(:not_connected, %{server: server.ref})}

    :exit, {:timeout, _call} ->
      {:error, Anubis.MCP.Error.transport(:timeout, %{server: server.ref})}
  end

  # A server everyone shares is reached over the deployment's own connection.
  # One each user reaches as themselves needs that user's credential, and a
  # connection of their own to carry it.
  defp connected(%Server{credential: nil}), do: {:ok, :deployment}

  defp connected(%Server{} = server) do
    case Scope.Context.current() do
      %Scope{} = scope -> connected(server, scope)
      nil -> {:error, "#{server.ref} is reached as a user, and this call has none"}
    end
  end

  defp connected(%Server{} = server, %Scope{} = scope) do
    principal = scope.user || :deployment

    if Connection.running?(server.ref, principal) do
      {:ok, principal}
    else
      open(server, scope, principal)
    end
  end

  defp open(%Server{} = server, %Scope{} = scope, principal) do
    with {:ok, credential} <- Credential.resolve(scope, server.credential),
         {:ok, transport} <- Server.with_credential(server, credential),
         good_for = Credential.remaining_ms(credential),
         {:ok, _pid} <- TarsMCP.Supervisor.connect(server, principal, transport, good_for),
         {:ok, _tools} <- Connection.await(server.ref, principal, :timer.seconds(30)) do
      {:ok, principal}
    else
      {:error, {:authorization_required, url}} ->
        {:park, "Authorize Tars for #{server.ref}, then say so: #{url}"}

      {:error, :no_resolver} ->
        {:error, "#{server.ref} needs a credential and this deployment resolves none"}

      {:error, reason} ->
        {:error, "#{server.ref} could not be reached as this user: #{inspect(reason)}"}
    end
  end

  # Progress is only worth reporting where there is a turn to report it to, and
  # the call it belongs to is the token the server echoes back.
  defp reporting(%Server{} = server, name) do
    with %Scope{} = scope <- Scope.Context.current(),
         %{id: call_id} <- Scope.Context.current_call() do
      local = Server.local_name(server, name)

      [
        progress: [
          token: call_id,
          callback: fn _token, progress, total ->
            Event.emit(scope.source, {:tool_progress, call_id, local, progress, total})
          end
        ]
      ]
    else
      _no_turn -> []
    end
  end

  # A model's arguments arrive with string keys already; a hand-written call is
  # as likely to use atoms, and converting only an all-atom map keeps the two
  # apart rather than merging them into each other.
  defp arguments(params) when is_map(params) do
    if Enum.all?(Map.keys(params), &is_atom/1) do
      Map.new(params, fn {key, value} -> {Atom.to_string(key), value} end)
    else
      params
    end
  end

  defp arguments(params) when is_list(params), do: params |> Map.new() |> arguments()
end
