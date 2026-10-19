defmodule WardrikHTTP.Router do
  @moduledoc """
  The HTTP API's routes; `WardrikHTTP` describes what each answers.

  Every response carries a `Request-Id` header, the caller's own where it sent
  one, and the request is logged under it. Every request comes from a
  `WardrikHTTP.Caller` (`WardrikHTTP.Auth`), who acts through `Wardrik` in a
  `Wardrik.Scope` holding their token: each route calls one of its
  functions, which checks the token and records each change in
  `Wardrik.Audit`, and answers what it answered as `Wardrik.JSON` shows
  it, and each `Wardrik.Error` with its status. `WardrikProtocol`'s
  `openapi.json` is every route, its parameters and its answers. An agent
  the caller's token does not reach is answered as one that does not exist,
  `404`, and one it reaches without the action, `403`. A stream of events,
  and a worker's socket, hold the caller's credential, and end when it is
  revoked.

  Its options are the `WardrikHTTP.Listener`'s `:host`, `:authenticator`,
  `:workers`, `:channels` and `:mounts`, assigned to each request as
  `:options`: every scope is on that host. A request to a path mounted with
  a plug of its own is that plug's alone.
  """

  use Plug.Router, copy_opts_to_assign: :options
  use Plug.ErrorHandler

  require Logger

  alias Wardrik.Agent.Message
  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Event.Cursor
  alias Wardrik.Event.Export
  alias Wardrik.JSON
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Role
  alias Wardrik.Scope
  alias Wardrik.Servers.Server
  alias Wardrik.Statement
  alias Wardrik.Token
  alias WardrikHTTP.Access
  alias WardrikHTTP.EventStream

  @parsers Plug.Parsers.init(parsers: [:json], json_decoder: Elixir.JSON, pass: ["*/*"])

  # The most of a request from outside, to a trigger or a channel, read,
  # which its signature is checked against whole.
  @outside_body 1_048_576

  @default_limit 100
  @max_limit 500

  # A worker's socket that carries nothing, not even the pong to a ping, for
  # this long is closed.
  @idle :timer.seconds(90)

  plug Plug.RequestId, http_header: "request-id"
  plug Plug.Logger
  plug :mounted
  plug WardrikHTTP.Auth
  plug :match
  plug :parse
  plug :dispatch

  get "/v1/workers" do
    serves? = Token.allows?(conn.assigns.caller.token, "agent.serve")

    case WebSockAdapter.UpgradeValidation.validate_upgrade(conn) do
      :ok when not serves? ->
        json(conn, 403, JSON.error("forbidden", "This caller may not offer tools."))

      :ok ->
        conn
        |> WebSockAdapter.upgrade(
          WardrikHTTP.Worker,
          %{
            caller: conn.assigns.caller,
            store: store(conn),
            settings: Keyword.get(conn.assigns.options, :workers, [])
          },
          timeout: @idle
        )
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_header("upgrade", "websocket")
        |> json(426, JSON.error("upgrade_required", "/v1/workers is a WebSocket."))
    end
  end

  # The agents ?resource= covers, or the one resource the caller's token
  # names where it names none.
  get "/v1/agents" do
    reply(
      conn,
      200,
      with(
        {:ok, pattern} <- resource(conn, :scope),
        do: Wardrik.agents_list(scope(conn), pattern)
      ),
      &%{"agents" => Enum.map(&1, fn member -> JSON.agent(member) end)}
    )
  end

  # Every agent ?resource= covers, which the request must name.
  post "/v1/agents/cancel" do
    reply(
      conn,
      202,
      with(
        {:ok, pattern} <- resource(conn, :named),
        do: Wardrik.agents_cancel(scope(conn), pattern)
      ),
      &JSON.cancelled/1
    )
  end

  delete "/v1/agents" do
    reply(
      conn,
      200,
      with(
        {:ok, pattern} <- resource(conn, :named),
        do: Wardrik.agents_forget(scope(conn), pattern)
      ),
      &JSON.forgotten/1
    )
  end

  # The calls agents ?resource= covers wait on a person for, or those the
  # one resource the caller's token names covers where it names none.
  get "/v1/interrupts" do
    reply(
      conn,
      200,
      with(
        {:ok, pattern} <- resource(conn, :scope),
        do: Wardrik.agents_parked(scope(conn), pattern)
      ),
      &JSON.interrupts/1
    )
  end

  # An export is a cursor of the caller's own, over every log it may read.
  match "/v1/exports/:name" do
    cond do
      not AgentID.segment?(name) ->
        invalid(
          conn,
          "#{inspect(name)} is not an export's name: a name holds no / or whitespace, " <>
            "and does not begin with @ or _"
        )

      not Token.allows?(conn.assigns.caller.token, "agent.events") ->
        json(conn, 403, JSON.error("forbidden", "This caller may not read events."))

      true ->
        export(conn, conn.method, "#{conn.assigns.caller.id}/#{name}")
    end
  end

  # The connections, and the MCP servers, of the owner ?owner= names: an
  # org, acme, or a person, acme/@jon.
  get "/v1/connections" do
    reply(
      conn,
      200,
      with({:ok, owner} <- owner(conn), do: Wardrik.connections_list(scope(conn), owner)),
      &JSON.connections/1
    )
  end

  post "/v1/connections/:provider" do
    reply(
      conn,
      200,
      with(
        {:ok, owner} <- owner(conn),
        do: Wardrik.connections_connect(scope(conn), owner, provider)
      ),
      &JSON.connecting/1
    )
  end

  delete "/v1/connections/:provider" do
    reply(
      conn,
      200,
      with(
        {:ok, owner} <- owner(conn),
        do: Wardrik.connections_disconnect(scope(conn), owner, provider)
      ),
      &%{"connection" => JSON.connection(&1)}
    )
  end

  get "/v1/servers" do
    reply(
      conn,
      200,
      with({:ok, owner} <- owner(conn), do: Wardrik.servers_list(scope(conn), owner)),
      &JSON.servers/1
    )
  end

  post "/v1/servers" do
    reply(
      conn,
      201,
      with(
        {:ok, owner} <- owner(conn),
        {:ok, fields} <- object(conn.body_params),
        {:ok, server} <- server(fields),
        do: Wardrik.servers_add(scope(conn), owner, server)
      ),
      &JSON.server_added/1
    )
  end

  delete "/v1/servers/:name" do
    reply(
      conn,
      200,
      with({:ok, owner} <- owner(conn), do: Wardrik.servers_remove(scope(conn), owner, name)),
      &%{"server" => JSON.server(&1)}
    )
  end

  # The deployment itself, to a token over deployment/*.
  post "/v1/deployment/reload" do
    reply(
      conn,
      200,
      Wardrik.deployment_reload(scope(conn)),
      &%{"reloaded" => Enum.map(&1, fn node -> to_string(node) end)}
    )
  end

  get "/v1/deployment/nodes",
    do: reply(conn, 200, Wardrik.deployment_nodes(scope(conn)), &JSON.nodes/1)

  get "/v1/deployment/audit", do: audit(conn)

  # The API's tokens, to a token over deployment/*.
  get "/v1/tokens", do: reply(conn, 200, Wardrik.tokens_list(scope(conn)), &JSON.tokens/1)

  post "/v1/tokens" do
    reply(
      conn,
      201,
      with(
        {:ok, name, statement, opts} <- token(conn.body_params),
        do: Wardrik.tokens_create(scope(conn), name, [statement], opts)
      ),
      &JSON.token_created/1
    )
  end

  delete "/v1/tokens/:id" do
    reply(conn, 200, Wardrik.tokens_revoke(scope(conn), id), &%{"token" => JSON.token(&1)})
  end

  # A request from outside to one of an agent's webhook triggers, at
  # /v1/hooks/{agent}/{trigger}, or with the trigger's secret after it for a
  # sender that sets no header: it holds no credential of this server's, so
  # it comes as the trigger it names, with a token allowing only delivery to
  # that agent, and the trigger checks it.
  post "/v1/hooks/:org/*rest" do
    case agent_path([org | rest]) do
      {segments, [trigger]} ->
        within(conn, segments, &hook(conn, &1, trigger))

      {segments, [trigger, secret]} ->
        conn = bearer(conn, secret)
        within(conn, segments, &hook(conn, &1, trigger))

      _other ->
        no_route(conn)
    end
  end

  # An agent is /v1/agents/{org}/{name}, or /v1/agents/{org}/@{user}/{name}
  # for a user's, and what follows its ID is what is asked of it.
  # A request a chat channel's medium sends, such as Slack's events, at
  # /v1/channels/{channel}/{path}: it holds no credential of this server's,
  # and the channel checks it as it answers it.
  post "/v1/channels/:channel/*rest" do
    channel(conn, channel, rest)
  end

  match "/v1/agents/:org/*rest" do
    with {segments, rest} <- agent_path([org | rest]),
         route when route != nil <- route(conn.method, rest, conn) do
      within(conn, segments, &answer(conn, route, &1))
    else
      nil -> no_route(conn)
    end
  end

  match _ do
    no_route(conn)
  end

  defp mounted(conn, _opts) do
    mounts = Keyword.get(conn.assigns.options, :mounts, [])

    case Enum.find(mounts, fn {path, _plug} -> List.starts_with?(conn.path_info, path) end) do
      {_path, {plug, options}} -> conn |> plug.call(plug.init(options)) |> halt()
      nil -> conn
    end
  end

  # A request to a trigger is checked against its body as it was sent, so it
  # is read whole rather than parsed.
  defp parse(%Plug.Conn{path_info: ["v1", "hooks" | _rest]} = conn, _opts), do: conn
  defp parse(%Plug.Conn{path_info: ["v1", "channels" | _rest]} = conn, _opts), do: conn
  defp parse(conn, _opts), do: Plug.Parsers.call(conn, @parsers)

  defp channel(conn, name, path) do
    with {:ok, {module, function, args}} <- Map.fetch(conn.assigns.options[:channels], name),
         {:ok, body, conn} <- read_body(conn, length: @outside_body) do
      conn = fetch_query_params(conn)

      %{status: status, headers: headers, body: answer} =
        apply(
          module,
          function,
          args ++
            [
              %{
                method: conn.method,
                path: path,
                query: conn.query_params,
                headers: conn.req_headers,
                body: body
              }
            ]
        )

      conn |> merge_resp_headers(headers) |> send_resp(status, answer)
    else
      :error ->
        json(conn, 404, JSON.error("not_found", "No channel #{name} takes requests here."))

      {:more, _read, conn} ->
        json(
          conn,
          413,
          JSON.error("invalid_request", "A request to a channel is at most 1 MB.")
        )
    end
  end

  # A secret in the path is the request's credential, as a bearer token is.
  defp bearer(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  defp hook(conn, agent, trigger) do
    case read_body(conn, length: @outside_body) do
      {:ok, body, conn} ->
        itself = AgentID.resource(agent)
        id = "#{itself}/trigger/#{trigger}"

        token = %Token{
          principal: Principal.new(:webhook, id),
          scope: [%Statement{actions: ["agent.trigger.deliver"], resources: [itself]}]
        }

        conn = assign(conn, :caller, %WardrikHTTP.Caller{id: id, name: trigger, token: token})

        reply(
          conn,
          202,
          Wardrik.agent_trigger_deliver(scope(conn), agent, trigger, %{
            headers: conn.req_headers,
            body: body
          }),
          &%{"delivery" => %{"status" => Atom.to_string(&1)}}
        )

      {:more, _read, conn} ->
        json(
          conn,
          413,
          JSON.error("invalid_request", "A request to a trigger is at most 1 MB.")
        )
    end
  end

  defp no_route(conn),
    do:
      json(
        conn,
        404,
        JSON.error("not_found", "No such route: #{conn.method} #{conn.request_path}")
      )

  # The segments of the ID at the front of an agent's path, and the rest.
  defp agent_path([org, "@" <> _user = user, name | rest]), do: {[org, user, name], rest}
  defp agent_path([org, name | rest]), do: {[org, name], rest}
  defp agent_path(_segments), do: nil

  # What each route asks of the agent: the status it answers with, the
  # function of `Wardrik` it calls with the session and the agent's ID, and
  # how it shows what that answers.
  defp route("GET", [], _conn), do: {200, &Wardrik.agent_read/2, &JSON.snapshot/1}

  defp route("PUT", [], conn) do
    {200,
     &with({:ok, fields} <- object(conn.body_params), do: Wardrik.agent_define(&1, &2, fields)),
     &JSON.snapshot/1}
  end

  defp route("DELETE", [], _conn), do: {204, &Wardrik.agent_forget/2, nil}

  defp route("GET", ["definition"], _conn),
    do:
      {200, &Wardrik.agent_definition_read/2,
       &%{"definition" => &1.definition.fields, "missing" => &1.missing}}

  defp route("GET", ["events"], conn), do: {:events, &events(conn, &1)}

  defp route("POST", ["messages"], conn) do
    {202,
     &with(
       {:ok, text, id} <- Message.read(conn.body_params),
       do: Wardrik.agent_ask(&1, &2, text, id: id)
     ), &%{"message" => %{"id" => &1.id}}}
  end

  defp route("POST", ["decisions"], conn) do
    {200,
     &with(
       {:ok, decisions} <- decisions(conn.body_params),
       do: Wardrik.agent_decide(&1, &2, decisions)
     ), &JSON.decisions/1}
  end

  defp route("GET", ["interrupts", id, "authorization"], _conn),
    do: {200, &Wardrik.agent_authorization_read(&1, &2, id), &JSON.authorization/1}

  defp route("POST", ["cancel"], _conn), do: {202, &Wardrik.agent_cancel/2, nil}

  defp route("DELETE", ["conversation"], _conn),
    do: {200, &Wardrik.agent_clear/2, &JSON.snapshot/1}

  defp route("POST", ["spawn"], conn), do: {200, &spawned(conn, &1, &2), &agent(&1.member)}
  defp route("POST", ["stop"], _conn), do: {200, &Wardrik.agent_stop/2, &agent/1}

  defp route("POST", ["move"], conn),
    do:
      {200,
       &with(
         {:ok, node} <- named(conn.body_params["node"]),
         do: Wardrik.agent_move(&1, &2, node)
       ), &agent/1}

  defp route("PUT", ["triggers", name], conn) do
    {200,
     &with(
       {:ok, fields} <- object(conn.body_params),
       do: Wardrik.agent_trigger_set(&1, &2, name, fields)
     ), &trigger/1}
  end

  defp route("DELETE", ["triggers", name], _conn),
    do: {200, &Wardrik.agent_trigger_remove(&1, &2, name), &trigger/1}

  defp route("GET", ["calls"], _conn), do: {200, &Wardrik.agent_calls/2, &JSON.calls/1}

  defp route("DELETE", ["calls", id], _conn),
    do: {204, &Wardrik.agent_call_kill(&1, &2, id), nil}

  defp route(_method, _rest, _conn), do: nil

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: %Plug.Parsers.ParseError{}}),
    do: json(conn, 400, JSON.error("invalid_request", "The body is not JSON."))

  def handle_errors(conn, _error),
    do: json(conn, conn.status, JSON.error("internal", "Something went wrong."))

  # A path segment is one segment of the ID: one that decodes to a "/" is
  # refused.
  defp within(conn, segments, fun) do
    text = Enum.join(segments, "/")

    case {Enum.find(segments, &String.contains?(&1, "/")), AgentID.parse(text)} do
      {nil, {:ok, key}} ->
        fun.(key)

      {nil, {:error, _message}} ->
        invalid(conn, "#{text} is not an agent ID; an ID is org/name or org/@user/name")

      {segment, _key} ->
        invalid(
          conn,
          "#{inspect(segment)} holds a /; an ID's org, user and name are a path segment each"
        )
    end
  end

  defp answer(_conn, {:events, fun}, key), do: fun.(key)

  defp answer(conn, {status, call, show}, key),
    do: reply(conn, status, call.(scope(conn), key), show)

  # Answers what a function of `Wardrik` answered: what it made, shown by
  # `show`, with `status`; `status` alone where it answers `:ok`; or its error.
  defp reply(conn, status, {:ok, value}, show), do: json(conn, status, show.(value))
  defp reply(conn, status, :ok, _show), do: send_resp(conn, status, "")
  defp reply(conn, _status, {:error, %Error{} = error}, _show), do: error(conn, error)

  defp agent(member), do: %{"agent" => JSON.agent(member)}
  defp trigger(trigger), do: %{"trigger" => trigger}

  defp scope(conn),
    do: Scope.new(Keyword.fetch!(conn.assigns.options, :host), conn.assigns.caller.token)

  # The pattern ?resource= names: where it names none, the one resource the
  # caller's token names, or for a request that must name one, why not.
  defp resource(conn, default) do
    case {conn.query_params["resource"], default, Token.resources(conn.assigns.caller.token)} do
      {nil, :scope, [pattern]} ->
        {:ok, pattern}

      {nil, _default, _resources} ->
        {:error, Error.new(:invalid, "resource names the agents, as acme/agent/*")}

      {text, _default, _resources} ->
        parsed(text)
    end
  end

  defp parsed(text) when is_binary(text) do
    case Resource.parse(text) do
      {:ok, pattern} -> {:ok, pattern}
      {:error, message} -> {:error, Error.new(:invalid, message)}
    end
  end

  defp parsed(_other), do: {:error, Error.new(:invalid, "A resource is a pattern, as acme/*")}

  # An org or a person, as ?owner= names them, never a pattern.
  defp owner(conn) do
    text = conn.query_params["owner"] || ""

    with false <- String.contains?(text, ["*", "?"]),
         {:ok, owner} <- Resource.parse(text),
         true <- Resource.owner(owner) == owner and owner != Resource.deployment() do
      {:ok, owner}
    else
      _other ->
        {:error, Error.new(:invalid, "owner names an org or a person, as acme or acme/@jon")}
    end
  end

  # The token a request makes, as `input_tokens_create.json` describes it.
  defp token(%{"name" => name, "resources" => [_ | _] = texts, "roles" => names} = body)
       when is_binary(name) and is_list(names) do
    with {:ok, resources} <- resources(texts),
         {:ok, roles} <- roles(names),
         {:ok, expires_in} <- expires_in(body["expires_in"]),
         {:ok, policy} <- policy(body["policy"]),
         do: {:ok, name, Role.bind(roles, resources), expires_in ++ policy}
  end

  defp token(_body),
    do: {:error, Error.new(:invalid, "A token is made with its name, resources and roles")}

  defp resources(texts) do
    Enum.reduce_while(Enum.reverse(texts), {:ok, []}, fn text, {:ok, patterns} ->
      case parsed(text) do
        {:ok, pattern} -> {:cont, {:ok, [pattern | patterns]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp roles(names) do
    case Role.parse(names) do
      {:ok, roles} -> {:ok, roles}
      {:error, message} -> {:error, Error.new(:invalid, message)}
    end
  end

  defp expires_in(nil), do: {:ok, []}

  defp expires_in(seconds) when is_integer(seconds) and seconds > 0,
    do: {:ok, [expires_in: seconds]}

  defp expires_in(_seconds),
    do: {:error, Error.new(:invalid, "expires_in is a number of seconds")}

  defp policy(nil), do: {:ok, []}
  defp policy(name) when is_binary(name) and name != "", do: {:ok, [policy: name]}
  defp policy(_name), do: {:error, Error.new(:invalid, "policy is the name of a policy")}

  # The server a request adds, as `input_servers_add.json` describes it.
  defp server(%{"name" => name, "auth" => %{} = auth} = fields)
       when is_binary(name) and map_size(auth) == 1 do
    [{kind, how}] = Map.to_list(auth)
    how = if is_map(how), do: how, else: %{}

    {:ok,
     %Server{
       name: name,
       url: fields["url"],
       auth: kind,
       secret: how["name"],
       header: how["header"],
       scheme: how["scheme"],
       scopes: how["scopes"],
       only: fields["only"],
       except: fields["except"]
     }}
  end

  defp server(_fields),
    do: {:error, Error.new(:invalid, "A server is added with its name, its URL and its auth")}

  # A spawn that names a node is the deployment's to make, and one that names
  # none any caller's who may define the agent.
  defp spawned(conn, session, key) do
    case conn.body_params do
      %{"node" => name} ->
        with {:ok, node} <- named(name), do: Wardrik.agent_spawn(session, key, node: node)

      _anywhere ->
        Wardrik.agent_spawn(session, key)
    end
  end

  # A node the deployment has, by its name: never an atom made from a request.
  defp named(name) when is_binary(name) do
    case Enum.find(Wardrik.Fleet.nodes(), &(Atom.to_string(&1) == name)) do
      nil -> {:error, Error.new(:invalid, "#{name} is not a node of this deployment.")}
      node -> {:ok, node}
    end
  end

  defp named(_name), do: {:error, Error.new(:invalid, "node is a node's name, as wardrik@host")}

  # The decisions a request takes, as `WardrikProtocol`'s `decisions.json`
  # describes them: each the id of a call, approve with a note for the agent
  # where one is given, or reject with a reason.
  defp decisions(%{"decisions" => [_ | _] = decisions}) do
    Enum.reduce_while(decisions, {:ok, %{}}, fn decision, {:ok, read} ->
      case decision(decision) do
        {:ok, id, decided} -> {:cont, {:ok, Map.put(read, id, decided)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp decisions(_body),
    do: {:error, Error.new(:invalid, "decisions is a list of a call's id and its decision")}

  defp decision(%{"id" => id, "decision" => "approve"} = decision) when is_binary(id) do
    case decision["note"] do
      note when is_binary(note) and note != "" -> {:ok, id, {:approve, note}}
      _none -> {:ok, id, :approve}
    end
  end

  defp decision(%{"id" => id, "decision" => "reject"} = decision) when is_binary(id) do
    case decision["reason"] do
      reason when is_binary(reason) and reason != "" -> {:ok, id, {:deny, reason}}
      _none -> {:ok, id, {:deny, "A person refused this call."}}
    end
  end

  defp decision(_decision),
    do: {:error, Error.new(:invalid, "Each decision is a call's id, and approve or reject")}

  # Plug.Parsers keeps a body that is not an object under "_json".
  defp object(%{"_json" => _value}),
    do: {:error, Error.new(:invalid, "The body is a JSON object")}

  defp object(fields), do: {:ok, fields}

  # -- the deployment --------------------------------------------------------

  defp audit(conn) do
    with {:ok, starting_after} <- sequence(conn.query_params["starting_after"], "starting_after"),
         {:ok, limit} <- limit(conn.query_params) do
      reply(
        conn,
        200,
        Wardrik.deployment_audit(scope(conn), after: starting_after || 0, limit: limit),
        &%{"changes" => Enum.map(&1, fn entry -> entry.event end)}
      )
    else
      {:error, message} -> invalid(conn, message)
    end
  end

  # -- events ----------------------------------------------------------------

  # A page is read as any route is; a stream checks the token itself, since
  # it goes on serving the caller.
  defp events(conn, key) do
    with {:ok, cursor} <- cursor(conn),
         {:ok, limit} <- limit(conn.query_params) do
      if stream?(conn),
        do: streamed(conn, key, cursor || :head),
        else: page(conn, key, cursor || 0, limit)
    else
      {:error, message} -> invalid(conn, message)
    end
  end

  defp page(conn, key, starting_after, limit) do
    resources = [AgentID.resource(key)]
    cursor = Cursor.encode(%{key => starting_after})

    reply(
      conn,
      200,
      with(
        {:ok, events} <- Wardrik.events(scope(conn), resources: resources, after: cursor),
        do: {:ok, Enum.take(events, limit)}
      ),
      &%{"events" => Enum.map(&1, fn entry -> entry.event end)}
    )
  end

  defp streamed(conn, key, cursor) do
    case Token.authorize(conn.assigns.caller.token, "agent.events", key) do
      :ok -> stream(conn, key, cursor)
      {:error, error} -> error(conn, error)
    end
  end

  defp cursor(conn) do
    case get_req_header(conn, "last-event-id") do
      [id | _] -> sequence(id, "Last-Event-ID")
      [] -> sequence(conn.query_params["starting_after"], "starting_after")
    end
  end

  defp sequence(nil, _name), do: {:ok, nil}

  defp sequence(value, name) do
    case Integer.parse(value) do
      {sequence, ""} when sequence >= 0 -> {:ok, sequence}
      _other -> {:error, "#{name} is a sequence number"}
    end
  end

  defp limit(%{"limit" => limit}) do
    case Integer.parse(limit) do
      {limit, ""} when limit in 1..@max_limit -> {:ok, limit}
      _other -> {:error, "limit is a number from 1 to #{@max_limit}"}
    end
  end

  defp limit(_params), do: {:ok, @default_limit}

  defp stream?(conn),
    do: Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "text/event-stream"))

  # The stream holds its caller's credential while it runs, so revoking the
  # credential ends it.
  defp stream(conn, key, cursor) do
    store = store(conn)

    store
    |> Access.holding(conn.assigns.caller.ref, fn ->
      EventStream.serve(conn, key, store: store, host: scope(conn).host, after: cursor)
    end)
    |> case do
      %Plug.Conn{} = conn ->
        conn

      {:gap, oldest} ->
        error(conn, Error.gap(oldest))

      :not_found ->
        error(conn, Error.no_agent(key))

      {:error, :not_found} ->
        json(conn, 401, JSON.error("unauthorized", "The credential was revoked."))

      {:error, :unavailable} ->
        unavailable(conn, "The credential cannot be checked now", :unavailable)
    end
  end

  # -- exports ---------------------------------------------------------------

  defp export(conn, "GET", cursor) do
    token = conn.assigns.caller.token

    case limit(conn.query_params) do
      {:ok, limit} ->
        {:ok, page} = Export.read(store(conn), cursor, limit: limit, logs: &exported?(token, &1))
        json(conn, 200, JSON.export(page))

      {:error, message} ->
        invalid(conn, message)
    end
  end

  defp export(conn, "POST", cursor) do
    with %{"next" => next} when is_binary(next) <- conn.body_params,
         :ok <- Export.advance(store(conn), cursor, next) do
      send_resp(conn, 204, "")
    else
      {:error, :invalid} -> invalid(conn, "next is not one a page of this export answered")
      {:error, reason} -> unavailable(conn, "The export did not move", reason)
      _body -> invalid(conn, "The body is a page's next, as {\"next\": …}")
    end
  end

  defp export(conn, "DELETE", cursor) do
    case Export.forget(store(conn), cursor) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> unavailable(conn, "The export was not deleted", reason)
    end
  end

  defp export(conn, _method, _cursor), do: no_route(conn)

  defp exported?(token, :audit),
    do: Token.authorize(token, "deployment.audit", Resource.parse!("deployment/*")) == :ok

  defp exported?(token, id), do: Token.authorize(token, "agent.events", id) == :ok

  defp store(conn), do: conn.assigns.options |> Keyword.fetch!(:host) |> Wardrik.Host.store()

  # -- answers ---------------------------------------------------------------

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Elixir.JSON.encode!(body))
  end

  @statuses %{
    unauthorized: 401,
    not_found: 404,
    forbidden: 403,
    invalid: 400,
    conflict: 409,
    gap: 410,
    unsupported: 501,
    unavailable: 503
  }

  defp error(conn, %Error{type: type} = error),
    do: json(conn, Map.fetch!(@statuses, type), JSON.error(error))

  defp invalid(conn, message), do: json(conn, 400, JSON.error("invalid_request", message))

  defp unavailable(conn, message, reason) do
    Logger.warning("#{message}: #{inspect(reason)}")
    json(conn, 503, JSON.error("unavailable", message <> "."))
  end
end
