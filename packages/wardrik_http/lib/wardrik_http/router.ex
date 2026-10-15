defmodule WardrikHTTP.Router do
  @moduledoc """
  The HTTP API's routes; `WardrikHTTP` describes what each answers.

  Every response carries a `Request-Id` header, the caller's own where it sent
  one, and the request is logged under it. Every request comes from a
  `WardrikHTTP.Caller` (`WardrikHTTP.Auth`). A route on an agent builds one
  of `Wardrik.Operations`' requests and runs it as a `Wardrik.Query` or a
  `Wardrik.Command`, which checks the caller's grant and records each change
  in `Wardrik.Audit`; the route answers what it answers, and each
  `Wardrik.Error` with its status. An agent outside the caller's scope is
  answered as one that does not exist, `404`, and one inside it the caller
  may not act on so, `403`. A stream of events, and a worker's socket, hold
  the caller's credential, and end when it is revoked.

  Its options are the `WardrikHTTP.Listener`'s `:host` and `:authenticator`,
  assigned to each request as `:options`: every operation a route runs is
  called with a `Wardrik.Caller` on that host.
  """

  use Plug.Router, copy_opts_to_assign: :options
  use Plug.ErrorHandler

  require Logger

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.AgentOperation
  alias Wardrik.Command
  alias Wardrik.Connections.Owner
  alias Wardrik.Error
  alias Wardrik.Event.Export
  alias Wardrik.Grant
  alias Wardrik.Operations.AddServer
  alias Wardrik.Operations.Ask
  alias Wardrik.Operations.Cancel
  alias Wardrik.Operations.CancelAgents
  alias Wardrik.Operations.Clear
  alias Wardrik.Operations.Connect
  alias Wardrik.Operations.Decide
  alias Wardrik.Operations.Define
  alias Wardrik.Operations.Deliver
  alias Wardrik.Operations.Disconnect
  alias Wardrik.Operations.Forget
  alias Wardrik.Operations.ForgetAgents
  alias Wardrik.Operations.ListAgents
  alias Wardrik.Operations.ListParked
  alias Wardrik.Operations.Move
  alias Wardrik.Operations.ReadAgent
  alias Wardrik.Operations.ReadAudit
  alias Wardrik.Operations.ReadAuthorization
  alias Wardrik.Operations.ReadConnections
  alias Wardrik.Operations.ReadDefinition
  alias Wardrik.Operations.ReadEvents
  alias Wardrik.Operations.ReadNodes
  alias Wardrik.Operations.ReadServers
  alias Wardrik.Operations.Reload
  alias Wardrik.Operations.RemoveServer
  alias Wardrik.Operations.RemoveTrigger
  alias Wardrik.Operations.SetTrigger
  alias Wardrik.Operations.Spawn
  alias Wardrik.Operations.SpawnOn
  alias Wardrik.Operations.Stop
  alias Wardrik.Principal
  alias Wardrik.Query
  alias Wardrik.Resource
  alias WardrikHTTP.Access
  alias WardrikHTTP.EventStream

  @parsers Plug.Parsers.init(parsers: [:json], json_decoder: JSON, pass: ["*/*"])

  # The most of a request to a trigger read, which its signature is checked
  # against whole.
  @hook_body 1_048_576

  @default_limit 100
  @max_limit 500

  # A worker's socket that carries nothing, not even the pong to a ping, for
  # this long is closed.
  @idle :timer.seconds(90)

  plug Plug.RequestId, http_header: "request-id"
  plug Plug.Logger
  plug WardrikHTTP.Auth
  plug :match
  plug :parse
  plug :dispatch

  get "/v1/workers" do
    serves? = :serve in conn.assigns.caller.grant.can

    case WebSockAdapter.UpgradeValidation.validate_upgrade(conn) do
      :ok when not serves? ->
        json(conn, 403, Resource.error("forbidden", "This caller may not offer tools."))

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
        |> json(426, Resource.error("upgrade_required", "/v1/workers is a WebSocket."))
    end
  end

  # The agents under ?prefix=, the caller's whole scope where it names none.
  get "/v1/agents", do: run(conn, Query, under(conn, ListAgents, :scope), 200)

  # Every agent under ?prefix=, which the request must name: prefix= alone is
  # every agent there is.
  post "/v1/agents/cancel", do: run(conn, Command, under(conn, CancelAgents, :named), 202)
  delete "/v1/agents", do: run(conn, Command, under(conn, ForgetAgents, :named), 200)

  # The calls agents under ?prefix= wait on a person for, under the caller's
  # whole scope where it names none.
  get "/v1/interrupts", do: run(conn, Query, under(conn, ListParked, :scope), 200)

  # An export is a cursor of the caller's own, over every log it may read.
  match "/v1/exports/:name" do
    cond do
      not AgentID.segment?(name) ->
        invalid(
          conn,
          "#{inspect(name)} is not an export's name: a name holds no / or whitespace, " <>
            "and does not begin with @ or _"
        )

      :read not in conn.assigns.caller.grant.can ->
        json(conn, 403, Resource.error("forbidden", "This caller may not read events."))

      true ->
        export(conn, conn.method, "#{conn.assigns.caller.id}/#{name}")
    end
  end

  # A caller's own connections, or with owner=org their org's.
  get "/v1/connections", do: run(conn, Query, connections(conn, ReadConnections, []), 200)

  post "/v1/connections/:provider",
    do: run(conn, Command, connections(conn, Connect, provider: provider), 200)

  delete "/v1/connections/:provider",
    do: run(conn, Command, connections(conn, Disconnect, provider: provider), 204)

  # The MCP servers a caller added for their own agents, or with owner=org
  # their org's.
  get "/v1/servers", do: run(conn, Query, servers(conn, ReadServers, %{}), 200)

  post "/v1/servers",
    do:
      run(
        conn,
        Command,
        with({:ok, fields} <- object(conn.body_params), do: servers(conn, AddServer, fields)),
        201
      )

  delete "/v1/servers/:name",
    do: run(conn, Command, servers(conn, RemoveServer, %{"name" => name}), 204)

  # The deployment itself, to a token over every agent.
  post "/v1/deployment/reload", do: run(conn, Command, {:ok, %Reload{}}, 200)
  get "/v1/deployment/nodes", do: run(conn, Query, {:ok, %ReadNodes{}}, 200)
  get "/v1/deployment/audit", do: audit(conn)

  # A request from outside to one of an agent's webhook triggers, at
  # /v1/hooks/{agent}/{trigger}, or with the trigger's secret after it for a
  # sender that sets no header: it holds no credential of this server's, so
  # it comes as the trigger it names, granted only to message that agent,
  # and the trigger checks it.
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

  # A request to a trigger is checked against its body as it was sent, so it
  # is read whole rather than parsed.
  defp parse(%Plug.Conn{path_info: ["v1", "hooks" | _rest]} = conn, _opts), do: conn
  defp parse(conn, _opts), do: Plug.Parsers.call(conn, @parsers)

  # A secret in the path is the request's credential, as a bearer token is.
  defp bearer(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  defp hook(conn, agent, trigger) do
    case read_body(conn, length: @hook_body) do
      {:ok, body, conn} ->
        {:ok, grant} = Grant.new(Prefix.of(agent), [:message])
        id = "#{agent}//#{trigger}"

        conn
        |> assign(:caller, %WardrikHTTP.Caller{
          id: id,
          name: trigger,
          principal: Principal.new(:webhook, id),
          grant: grant
        })
        |> run(
          Command,
          {:ok, %Deliver{agent: agent, trigger: trigger, headers: conn.req_headers, body: body}},
          202
        )

      {:more, _read, conn} ->
        json(
          conn,
          413,
          Resource.error("invalid_request", "A request to a trigger is at most 1 MB.")
        )
    end
  end

  defp no_route(conn),
    do:
      json(
        conn,
        404,
        Resource.error("not_found", "No such route: #{conn.method} #{conn.request_path}")
      )

  # The segments of the ID at the front of an agent's path, and the rest.
  defp agent_path([org, "@" <> _user = user, name | rest]), do: {[org, user, name], rest}
  defp agent_path([org, name | rest]), do: {[org, name], rest}
  defp agent_path(_segments), do: nil

  # What each route asks of the agent: the operation it builds from the
  # agent's ID and the request, and the status that answers it where it
  # answers something. The operation checks the caller's grant.
  defp route("GET", [], _conn), do: {Query, &{:ok, %ReadAgent{agent: &1}}, 200}
  defp route("PUT", [], conn), do: {Command, &define(conn, &1), 200}
  defp route("DELETE", [], _conn), do: {Command, &{:ok, %Forget{agent: &1}}, 200}
  defp route("GET", ["definition"], _conn), do: {Query, &{:ok, %ReadDefinition{agent: &1}}, 200}
  defp route("GET", ["events"], conn), do: {:events, &events(conn, &1)}
  defp route("POST", ["messages"], conn), do: {Command, &Ask.new(&1, conn.body_params), 202}

  defp route("POST", ["decisions"], conn), do: {Command, &Decide.new(&1, conn.body_params), 200}

  defp route("GET", ["interrupts", id, "authorization"], _conn),
    do: {Query, &{:ok, %ReadAuthorization{agent: &1, interrupt: id}}, 200}

  defp route("POST", ["cancel"], _conn), do: {Command, &{:ok, %Cancel{agent: &1}}, 202}
  defp route("DELETE", ["conversation"], _conn), do: {Command, &{:ok, %Clear{agent: &1}}, 204}
  defp route("POST", ["spawn"], conn), do: {Command, &spawn(conn, &1), 200}
  defp route("POST", ["stop"], _conn), do: {Command, &{:ok, %Stop{agent: &1}}, 200}
  defp route("POST", ["move"], conn), do: {Command, &move(conn, &1), 200}

  defp route("PUT", ["triggers", name], conn),
    do: {Command, &trigger(conn, &1, name), 200}

  defp route("DELETE", ["triggers", name], _conn),
    do: {Command, &{:ok, %RemoveTrigger{agent: &1, name: name}}, 204}

  defp route(_method, _rest, _conn), do: nil

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: %Plug.Parsers.ParseError{}}),
    do: json(conn, 400, Resource.error("invalid_request", "The body is not JSON."))

  def handle_errors(conn, _error),
    do: json(conn, conn.status, Resource.error("internal", "Something went wrong."))

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

  defp answer(conn, {kind, request, status}, key), do: run(conn, kind, request.(key), status)

  # Runs the operation a route built, or answers why it could not be built.
  defp run(conn, Query, request, status) do
    with {:ok, request} <- request,
         {:ok, body} <- Query.run(request, caller(conn)) do
      json(conn, status, body)
    else
      {:error, error} -> error(conn, error)
    end
  end

  # With ?plan=true, a command answers what it would do, and does nothing.
  defp run(%{query_params: %{"plan" => "true"}} = conn, Command, request, _status) do
    with {:ok, request} <- request,
         {:ok, change} <- Command.plan(request, caller(conn)) do
      json(conn, 200, Command.preview(change))
    else
      {:error, error} -> error(conn, error)
    end
  end

  defp run(conn, Command, request, status) do
    answered = with {:ok, request} <- request, do: Command.run(request, caller(conn))

    case answered do
      {:ok, nil} -> send_resp(conn, 204, "")
      {:ok, body} -> json(conn, status, body)
      {:created, body} -> json(conn, 201, body)
      {:error, error} -> error(conn, error)
    end
  end

  # The request of `module` under the prefix ?prefix= names: where it names
  # none, the caller's whole scope, or for a request that must name one, why
  # not.
  defp under(conn, module, default) do
    case {conn.query_params["prefix"], default} do
      {nil, :scope} -> {:ok, struct!(module, prefix: conn.assigns.caller.grant.scope)}
      {nil, :named} -> {:error, Error.new(:invalid, "prefix names the agents, as acme/")}
      {text, _default} -> prefixed(module, text)
    end
  end

  defp prefixed(module, text) do
    case Prefix.parse(text) do
      {:ok, prefix} -> {:ok, struct!(module, prefix: prefix)}
      {:error, message} -> {:error, Error.new(:invalid, message)}
    end
  end

  # The request about the caller's own connections, or with owner=org their
  # org's.
  defp connections(conn, module, fields) do
    with {:ok, whose} <- whose(conn), do: Owner.request(module, caller(conn), whose, fields)
  end

  # The request about the caller's own servers, or with owner=org their org's,
  # from the operation's catalog input.
  defp servers(conn, module, input) do
    with {:ok, whose} <- whose(conn),
         {:ok, owner} <- Owner.owner(caller(conn), whose),
         do: module.new(owner, input)
  end

  defp whose(conn) do
    case conn.query_params["owner"] do
      nil -> {:ok, :person}
      "org" -> {:ok, :org}
      _other -> {:error, Error.new(:invalid, "owner is org, or left out for the caller's own")}
    end
  end

  defp caller(conn) do
    Wardrik.Caller.new(
      principal: conn.assigns.caller.principal,
      grant: conn.assigns.caller.grant,
      host: Keyword.fetch!(conn.assigns.options, :host)
    )
  end

  defp define(conn, key) do
    with {:ok, fields} <- object(conn.body_params),
         do: {:ok, %Define{agent: key, definition: fields}}
  end

  # A spawn that names a node is the deployment's to make, and one that names
  # none any caller's who may define the agent.
  defp spawn(conn, key) do
    case conn.body_params do
      %{"node" => name} ->
        with {:ok, node} <- named(name), do: {:ok, %SpawnOn{agent: key, node: node}}

      _anywhere ->
        {:ok, %Spawn{agent: key}}
    end
  end

  defp move(conn, key) do
    with {:ok, node} <- named(conn.body_params["node"]), do: {:ok, %Move{agent: key, node: node}}
  end

  # A node the deployment has, by its name: never an atom made from a request.
  defp named(name) when is_binary(name) do
    case Enum.find([Node.self() | Node.list()], &(Atom.to_string(&1) == name)) do
      nil -> {:error, Error.new(:invalid, "#{name} is not a node of this deployment.")}
      node -> {:ok, node}
    end
  end

  defp named(_name), do: {:error, Error.new(:invalid, "node is a node's name, as wardrik@host")}

  defp trigger(conn, key, name) do
    with {:ok, fields} <- object(conn.body_params),
         do: {:ok, %SetTrigger{agent: key, name: name, fields: fields}}
  end

  # Plug.Parsers keeps a body that is not an object under "_json".
  defp object(%{"_json" => _value}),
    do: {:error, Error.new(:invalid, "The body is a JSON object")}

  defp object(fields), do: {:ok, fields}

  # -- the deployment --------------------------------------------------------

  defp audit(conn) do
    with {:ok, starting_after} <- sequence(conn.query_params["starting_after"], "starting_after"),
         {:ok, limit} <- limit(conn.query_params) do
      request = %ReadAudit{starting_after: starting_after || 0, limit: limit}
      run(conn, Query, {:ok, request}, 200)
    else
      {:error, message} -> invalid(conn, message)
    end
  end

  # -- events ----------------------------------------------------------------

  # A page is read as any query is; a stream checks the grant itself, since
  # it goes on serving the caller.
  defp events(conn, key) do
    with {:ok, cursor} <- cursor(conn),
         {:ok, limit} <- limit(conn.query_params) do
      if stream?(conn),
        do: streamed(conn, key, cursor || :head),
        else: answer(conn, {Query, &page(&1, cursor || 0, limit), 200}, key)
    else
      {:error, message} -> invalid(conn, message)
    end
  end

  defp page(key, starting_after, limit),
    do: {:ok, %ReadEvents{agent: key, starting_after: starting_after, limit: limit}}

  defp streamed(conn, key, cursor) do
    case Wardrik.Subject.authorize(key, conn.assigns.caller.grant, :read) do
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
      EventStream.serve(conn, key, store: store, after: cursor)
    end)
    |> case do
      %Plug.Conn{} = conn ->
        conn

      {:gap, oldest} ->
        error(conn, ReadEvents.gap(oldest))

      :not_found ->
        error(conn, AgentOperation.not_found(key))

      {:error, :not_found} ->
        json(conn, 401, Resource.error("unauthorized", "The credential was revoked."))

      {:error, :unavailable} ->
        unavailable(conn, "The credential cannot be checked now", :unavailable)
    end
  end

  # -- exports ---------------------------------------------------------------

  defp export(conn, "GET", cursor) do
    grant = conn.assigns.caller.grant

    case limit(conn.query_params) do
      {:ok, limit} ->
        {:ok, page} = Export.read(store(conn), cursor, limit: limit, logs: &exported?(grant, &1))
        json(conn, 200, Resource.export(page))

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

  # The audit is read by a caller that reaches every agent, and an agent's
  # log by one that may read the agent.
  defp exported?(grant, :audit), do: Prefix.covers?(grant.scope, Prefix.all())
  defp exported?(grant, id), do: Access.authorize(grant, :read, id) == :ok

  defp store(conn), do: conn.assigns.options |> Keyword.fetch!(:host) |> Wardrik.Host.store()

  # -- answers ---------------------------------------------------------------

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  @statuses %{
    not_found: 404,
    forbidden: 403,
    invalid: 400,
    conflict: 409,
    gap: 410,
    unsupported: 501,
    unavailable: 503
  }

  defp error(conn, %Error{type: type} = error),
    do: json(conn, Map.fetch!(@statuses, type), Resource.error(error))

  defp invalid(conn, message), do: json(conn, 400, Resource.error("invalid_request", message))

  defp unavailable(conn, message, reason) do
    Logger.warning("#{message}: #{inspect(reason)}")
    json(conn, 503, Resource.error("unavailable", message <> "."))
  end
end
