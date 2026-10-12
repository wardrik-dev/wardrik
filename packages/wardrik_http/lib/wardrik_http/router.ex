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

  Its option is the `WardrikHTTP.Listener`'s `:authenticator`, assigned to
  each request as `:options`.
  """

  use Plug.Router, copy_opts_to_assign: :options
  use Plug.ErrorHandler

  require Logger

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.AgentOperation
  alias Wardrik.Command
  alias Wardrik.Connections
  alias Wardrik.Error
  alias Wardrik.Event.Export
  alias Wardrik.Fleet
  alias Wardrik.Operations.Ask
  alias Wardrik.Operations.Cancel
  alias Wardrik.Operations.Clear
  alias Wardrik.Operations.Connect
  alias Wardrik.Operations.Decide
  alias Wardrik.Operations.Define
  alias Wardrik.Operations.Disconnect
  alias Wardrik.Operations.Forget
  alias Wardrik.Operations.ReadAgent
  alias Wardrik.Operations.ReadAuthorization
  alias Wardrik.Operations.ReadConnections
  alias Wardrik.Operations.ReadDefinition
  alias Wardrik.Operations.ReadEvents
  alias Wardrik.Operations.RemoveTrigger
  alias Wardrik.Operations.SetTrigger
  alias Wardrik.Query
  alias Wardrik.Resource
  alias WardrikHTTP.Access
  alias WardrikHTTP.EventStream

  @default_limit 100
  @max_limit 500

  # A worker's socket that carries nothing, not even the pong to a ping, for
  # this long is closed.
  @idle :timer.seconds(90)

  plug Plug.RequestId, http_header: "request-id"
  plug Plug.Logger
  plug WardrikHTTP.Auth
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"]
  plug :dispatch

  get "/v1/workers" do
    serves? = :serve in conn.assigns.caller.grant.can

    case WebSockAdapter.UpgradeValidation.validate_upgrade(conn) do
      :ok when not serves? ->
        json(conn, 403, Resource.error("forbidden", "This caller may not offer tools."))

      :ok ->
        conn
        |> WebSockAdapter.upgrade(WardrikHTTP.Worker, conn.assigns.caller, timeout: @idle)
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_header("upgrade", "websocket")
        |> json(426, Resource.error("upgrade_required", "/v1/workers is a WebSocket."))
    end
  end

  get "/v1/agents" do
    grant = conn.assigns.caller.grant

    agents =
      for member <- Fleet.list(grant.scope),
          Access.authorize(grant, :read, member.id) == :ok,
          do: Resource.agent(member)

    json(conn, 200, %{"agents" => agents})
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
  defp route("DELETE", [], _conn), do: {Command, &{:ok, %Forget{agent: &1}}, 204}
  defp route("GET", ["definition"], _conn), do: {Query, &{:ok, %ReadDefinition{agent: &1}}, 200}
  defp route("GET", ["events"], conn), do: {:events, &events(conn, &1)}
  defp route("POST", ["messages"], conn), do: {Command, &Ask.new(&1, conn.body_params), 202}

  defp route("POST", ["decisions"], conn), do: {Command, &Decide.new(&1, conn.body_params), 200}

  defp route("GET", ["interrupts", id, "authorization"], _conn),
    do: {Query, &{:ok, %ReadAuthorization{agent: &1, interrupt: id}}, 200}

  defp route("POST", ["cancel"], _conn), do: {Command, &{:ok, %Cancel{agent: &1}}, 202}
  defp route("DELETE", ["conversation"], _conn), do: {Command, &{:ok, %Clear{agent: &1}}, 204}

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

  defp run(conn, Command, request, status) do
    answered = with {:ok, request} <- request, do: Command.run(request, caller(conn))

    case answered do
      {:ok, nil} -> send_resp(conn, 204, "")
      {:ok, body} -> json(conn, status, body)
      {:created, body} -> json(conn, 201, body)
      {:error, error} -> error(conn, error)
    end
  end

  # The request about the caller's own connections, or with owner=org their
  # org's.
  defp connections(conn, module, fields) do
    case conn.query_params["owner"] do
      nil -> Connections.request(module, caller(conn), :person, fields)
      "org" -> Connections.request(module, caller(conn), :org, fields)
      _other -> {:error, Error.new(:invalid, "owner is org, or left out for the caller's own")}
    end
  end

  defp caller(conn),
    do: Wardrik.Caller.new(conn.assigns.caller.principal, conn.assigns.caller.grant)

  defp define(conn, key) do
    with {:ok, fields} <- object(conn.body_params),
         do: {:ok, %Define{agent: key, definition: fields}}
  end

  defp trigger(conn, key, name) do
    with {:ok, fields} <- object(conn.body_params),
         do: {:ok, %SetTrigger{agent: key, name: name, fields: fields}}
  end

  # Plug.Parsers keeps a body that is not an object under "_json".
  defp object(%{"_json" => _value}),
    do: {:error, Error.new(:invalid, "The body is a JSON object")}

  defp object(fields), do: {:ok, fields}

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
    conn.assigns.caller.ref
    |> Access.holding(fn -> EventStream.serve(conn, key, cursor) end)
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
        {:ok, page} = Export.read(cursor, limit: limit, logs: &exported?(grant, &1))
        json(conn, 200, Resource.export(page))

      {:error, message} ->
        invalid(conn, message)
    end
  end

  defp export(conn, "POST", cursor) do
    with %{"next" => next} when is_binary(next) <- conn.body_params,
         :ok <- Export.advance(cursor, next) do
      send_resp(conn, 204, "")
    else
      {:error, :invalid} -> invalid(conn, "next is not one a page of this export answered")
      {:error, reason} -> unavailable(conn, "The export did not move", reason)
      _body -> invalid(conn, "The body is a page's next, as {\"next\": …}")
    end
  end

  defp export(conn, "DELETE", cursor) do
    case Export.forget(cursor) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> unavailable(conn, "The export was not deleted", reason)
    end
  end

  defp export(conn, _method, _cursor), do: no_route(conn)

  # The audit is read by a caller that reaches every agent, and an agent's
  # log by one that may read the agent.
  defp exported?(grant, :audit), do: Prefix.covers?(grant.scope, Prefix.all())
  defp exported?(grant, id), do: Access.authorize(grant, :read, id) == :ok

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
