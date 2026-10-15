defmodule WardrikMCP do
  @moduledoc """
  MCP servers as tools an agent can call.

  A host starts `WardrikMCP.Supervisor` with the servers it wants reached, then
  names one by its `Wardrik.Servers.Key` in a config the way it names any
  other tool:

      Wardrik.LLM.Config.new(tools: [{WardrikMCP, Wardrik.Servers.Key.deployment("github")}])

  The spec is a `Wardrik.Tool` source: it stands for however many tools that
  server offers, and it travels, so an agent that moves to another node builds
  the same tools again there. A server that is not connected offers none, and
  the config is still valid.

  `{WardrikMCP, :*}` names every server connected on the node running the agent,
  rather than one:

      Wardrik.LLM.Config.new(tools: [{WardrikMCP, :*}])

  A server's `:serves` limits which agents it serves, by prefix. A call from an
  agent under none of them is refused, so an agent that is not to see a
  server's tools names the servers it is given, rather than `:*`.

  Both are read again for every turn, so a config outlives the servers it was
  built alongside.

  Tool names are the server's name, then the remote name: `github__create_issue`.

  ## Configuration

  The servers are options of `WardrikMCP.Supervisor`, which the host starts in
  its own tree:

      {WardrikMCP.Supervisor,
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
       ]}

  See `WardrikMCP.Server` for every option a server takes. A credential is part of
  the transport: `:env` for a command, `:headers` for HTTP. Wardrik holds no token
  of its own and runs no OAuth flow; a server that needs one is given a token
  that was minted elsewhere.
  """

  @behaviour Wardrik.Tool

  alias Wardrik.Credential
  alias Wardrik.Scope
  alias Wardrik.Servers.Key
  alias Wardrik.Tool
  alias Wardrik.Tool.Result
  alias WardrikMCP.Connection
  alias WardrikMCP.Offer
  alias WardrikMCP.Remotes
  alias WardrikMCP.Server

  @timeout :timer.seconds(60)

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
  @impl Wardrik.Tool
  @spec tools(Key.t() | :*) :: [ReqLLM.Tool.t()]
  def tools(source), do: source |> keys() |> Enum.flat_map(&offered/1)

  @doc """
  What holds for the tool the agent knows as `name`: whether the server
  offering it gates it (see `WardrikMCP.Server`), that its answers are
  labelled `"outside"` for every server `:trusted` does not mark as the
  deployment's own, and for a tool no connected server offers, the credential the server
  is reached with, and how long a call may take unless the server says
  otherwise. The tool that connects a server is never gated, since it changes
  nothing but who is connected.
  """
  @impl Wardrik.Tool
  def annotations(source, name) do
    case offering(source, name) do
      {server, :connect} ->
        %{credentials: List.wrap(server.credential), timeout: @timeout}

      {server, remote, read_only?} ->
        %{
          gated: Server.gated?(server, remote, read_only?),
          labels: if(server.trusted, do: [], else: ["outside"]),
          credentials: List.wrap(server.credential),
          timeout: @timeout
        }

      nil ->
        %{labels: ["outside"], timeout: @timeout}
    end
  end

  # The server offering the tool the agent knows as `name`, among the
  # source's, and the tool's own name there and whether the server marks it
  # read-only, or `:connect` for the tool that connects the server.
  defp offering(source, name) do
    Enum.find_value(keys(source), fn key ->
      with %Offer{server: server, tools: tools, read_only: read_only} <- offer(key),
           %ReqLLM.Tool{callback: {Tool, :invoke, [{__MODULE__, function, args}]}} <-
             Enum.find(tools, &(&1.name == name)) do
        offered(server, read_only, function, args)
      else
        _none -> nil
      end
    end)
  end

  defp offered(server, read_only, :call, [_key, remote]),
    do: {server, remote, remote in read_only}

  defp offered(server, _read_only, :authorize, [_key]), do: {server, :connect}

  defp keys(:*), do: servers()
  defp keys(%Key{} = key), do: [key]

  # What a server is offering on this node: one of the deployment's own, or
  # one an owner added, whose connection starts here the first time it is
  # asked for.
  defp offer(key), do: Connection.offer(key) || Remotes.offer(key)

  defp offered(key) do
    case offer(key) do
      %Offer{tools: tools} -> tools
      nil -> []
    end
  end

  @doc """
  Calls a tool on a server and reports what it answered.

  What a tool built by `WardrikMCP.Tool.build/2` runs; the key and the remote
  name are the ones it was built with, and `input` and `context` are what the
  runtime hands it; see `Wardrik.Tool`.

  The call reports the server's progress as
  `Wardrik.Event.ToolProgress` on the turn's event
  stream, and is cancelled on the server if this process is stopped before the
  server answers.

  A server with a `:credential` is called over a connection belonging to
  whoever the credential the runtime resolved for the call belongs to: it is
  named in the tool's annotations, so the runtime resolves it, parks the call
  where the user has yet to authorize, and hands it in the context. A server
  that refuses the credential it was given is answered `{:refused, name}`, so
  the runtime tells the resolver, resolves it afresh and calls again, which
  covers a token revoked or expired without warning.
  """
  @spec call(Key.t(), String.t(), map(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.answer()
  def call(%Key{} = key, name, input, %Wardrik.Tool.Context{} = context) do
    with %Offer{server: server} <- offer(key),
         :ok <- serves(server, context.scope),
         {:ok, principal} <- connected(server, context.credentials[server.credential]) do
      :ok = Connection.watch(key, principal)
      answer = key |> Connection.client(principal) |> request(server, name, input, context)

      if refused?(answer) and Server.per_user?(server) do
        Connection.close(key, principal)
        {:refused, server.credential}
      else
        WardrikMCP.Tool.answer(answer, server)
      end
    else
      nil -> Result.error(:no_such_server, "no MCP server is connected as #{key}")
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
  Says the calling user is authorized for a server, once the runtime has
  resolved its credential for them, and opens their connection, which lists
  the server's real tools in place of the one that connects it.

  What the tool `WardrikMCP.Tool.connect/1` builds runs. A user who has not
  authorized yet never reaches it: the credential is named in the tool's
  annotations, so the runtime parks the call on the link first.
  """
  @spec authorize(Key.t(), map(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.answer()
  def authorize(%Key{} = key, _input, %Wardrik.Tool.Context{} = context) do
    with %Offer{server: server} <- offer(key),
         :ok <- serves(server, context.scope),
         {:ok, _principal} <- connected(server, context.credentials[server.credential]) do
      Result.ok(%{"connected" => true, "server" => to_string(key)})
    else
      nil -> Result.error(:no_such_server, "no MCP server is connected as #{key}")
      {:error, reason} -> Result.error(:not_authorized, reason)
    end
  end

  @doc "Connects to a server that was not in the configuration."
  @spec connect(Key.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(%Key{} = key, opts) when is_list(opts) do
    WardrikMCP.Supervisor.connect(Server.new(key, opts))
  end

  @doc "Stops a connection and drops the tools it was offering."
  @spec disconnect(Key.t()) :: :ok | {:error, :not_found}
  def disconnect(%Key{} = key), do: WardrikMCP.Supervisor.disconnect(key)

  @doc """
  The keys of the deployment's own servers, those `WardrikMCP.Supervisor`
  was started with or `connect/2` added, which `:*` names.
  """
  @spec servers() :: [Key.t()]
  def servers, do: for(server <- WardrikMCP.Supervisor.servers(), do: server.key)

  @doc "Stops every connection to the server `key` names on this node."
  @spec close(Key.t()) :: :ok
  def close(%Key{} = key) do
    for principal <- Connection.principals(key), do: Connection.close(key, principal)
    :ok
  end

  defp request(client, server, name, input, context) do
    opts = [timeout: server.timeout] ++ reporting(context)

    Anubis.Client.call_tool(client, name, arguments(input), opts)
  catch
    :exit, {:noproc, _call} ->
      {:error, Anubis.MCP.Error.transport(:not_connected, %{server: to_string(server.key)})}

    :exit, {:timeout, _call} ->
      {:error, Anubis.MCP.Error.transport(:timeout, %{server: to_string(server.key)})}
  end

  defp serves(%Server{} = server, %Scope{} = scope) do
    id = Scope.agent_id(scope)

    if Server.serves?(server, id),
      do: :ok,
      else: {:error, "#{server.key} does not serve #{id}"}
  end

  # A server everyone shares is reached over the deployment's own connection.
  # One reached with a credential needs a connection for whoever the
  # credential resolved belongs to, carrying theirs and no one else's: a
  # user's, an org's, or the deployment's, over one of its own rather than
  # the one that lists the server's tools.
  defp connected(%Server{credential: nil}, _credential), do: {:ok, :deployment}

  defp connected(%Server{} = server, nil),
    do:
      {:error, "#{server.key} needs its credential, #{server.credential}, and none was resolved"}

  defp connected(%Server{} = server, %Credential{owner: owner} = credential) do
    principal = {:owner, owner}

    if Connection.running?(server.key, principal),
      do: {:ok, principal},
      else: open(server, principal, credential)
  end

  defp open(%Server{} = server, principal, credential) do
    with {:ok, transport} <- Server.with_credential(server, credential),
         good_for = Credential.remaining_ms(credential),
         {:ok, _pid} <- WardrikMCP.Supervisor.connect(server, principal, transport, good_for),
         {:ok, _tools} <- Connection.await(server.key, principal, :timer.seconds(30)) do
      {:ok, principal}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "#{server.key} could not be reached: #{inspect(reason)}"}
    end
  end

  # The call's id is the token the server echoes back, and the reporter is
  # bound here because the callback runs in the client's process.
  defp reporting(%Wardrik.Tool.Context{call_id: id} = context) do
    [
      progress: [
        token: id,
        callback: fn _token, progress, total ->
          Wardrik.Tool.Context.progress(context, progress, total)
        end
      ]
    ]
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
