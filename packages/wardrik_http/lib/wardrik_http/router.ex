defmodule WardrikHTTP.Router do
  @moduledoc """
  The HTTP API's routes; `WardrikHTTP` describes what each answers.

  Every response carries a `Request-Id` header, the caller's own where it sent
  one, and the request is logged under it. Every request comes from a
  `WardrikHTTP.Caller` (`WardrikHTTP.Auth`), and each route asks
  `WardrikHTTP.Access.authorize/3` for the action it takes: an agent outside
  the caller's scope is answered as one that does not exist, `404`, and one
  inside it the caller may not act on so, `403`. A stream of events, and a
  worker's socket, hold the caller's credential, and end when it is revoked.

  Each change a route makes is recorded in `Wardrik.Audit` once it is made,
  with the caller's principal.

  Its options are the `WardrikHTTP.Listener`'s `:definition` and
  `:authenticator`, assigned to each request as `:options`.
  """

  use Plug.Router, copy_opts_to_assign: :options
  use Plug.ErrorHandler

  require Logger

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Audit
  alias Wardrik.Event.Export
  alias Wardrik.Event.Log
  alias Wardrik.Fleet
  alias Wardrik.Grant
  alias WardrikHTTP.Access
  alias WardrikHTTP.EventStream
  alias WardrikHTTP.Resource

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

  # An agent is /v1/agents/{org}/{name}, or /v1/agents/{org}/@{user}/{name}
  # for a user's, and what follows its ID is what is asked of it.
  match "/v1/agents/:org/*rest" do
    with {segments, rest} <- agent_path([org | rest]),
         {action, fun} <- route(conn.method, rest) do
      within(conn, segments, action, &fun.(conn, &1))
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

  defp route("GET", []), do: {:read, &snapshot/2}
  defp route("PUT", []), do: {:define, &define/2}
  defp route("DELETE", []), do: {:define, &forget/2}
  defp route("GET", ["definition"]), do: {:read, &definition/2}
  defp route("GET", ["events"]), do: {:read, &events/2}
  defp route("POST", ["messages"]), do: {:message, &ask/2}
  defp route("POST", ["interrupts", id]), do: {:decide, &decide(&1, &2, id)}

  defp route("GET", ["interrupts", id, "authorization"]),
    do: {:decide, &authorization(&1, &2, id)}

  defp route("POST", ["cancel"]), do: {:message, &cancel/2}
  defp route("DELETE", ["conversation"]), do: {:message, &clear/2}
  defp route("PUT", ["schedules", schedule]), do: {:define, &schedule(&1, &2, schedule)}
  defp route("DELETE", ["schedules", schedule]), do: {:define, &unschedule(&1, &2, schedule)}
  defp route(_method, _rest), do: nil

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: %Plug.Parsers.ParseError{}}),
    do: json(conn, 400, Resource.error("invalid_request", "The body is not JSON."))

  def handle_errors(conn, _error),
    do: json(conn, conn.status, Resource.error("internal", "Something went wrong."))

  # A path segment is one segment of the ID: one that decodes to a "/" is
  # refused. An agent the caller does not reach is one that does not exist,
  # to the caller. Every handler below is given the agent's ID as `key`.
  defp within(conn, segments, action, fun) do
    text = Enum.join(segments, "/")

    case {Enum.find(segments, &String.contains?(&1, "/")), AgentID.parse(text)} do
      {nil, {:ok, key}} ->
        case Access.authorize(conn.assigns.caller.grant, action, key) do
          :ok -> fun.(key)
          {:error, :forbidden} -> forbidden(conn, action, key)
          {:error, :not_found} -> not_found(conn, key)
        end

      {nil, {:error, _message}} ->
        invalid(conn, "#{text} is not an agent ID; an ID is org/name or org/@user/name")

      {segment, _key} ->
        invalid(
          conn,
          "#{inspect(segment)} holds a /; an ID's org, user and name are a path segment each"
        )
    end
  end

  defp snapshot(conn, key) do
    case Agent.snapshot(key) do
      {:error, :not_found} -> not_found(conn, key)
      snapshot -> json(conn, 200, Resource.snapshot(key, snapshot))
    end
  end

  # -- definitions -----------------------------------------------------------

  defp define(conn, key) do
    with {:ok, module} <- definitions(conn, :put),
         {:ok, fields} <- object(conn.body_params),
         {:ok, spec} <- module.put(key, fields, conn.assigns.caller.grant) do
      if spec.id == key,
        do:
          put_agent(conn, key, %{spec | hooks: Grant.held(conn.assigns.caller.grant, spec.hooks)}),
        else: internal(conn, "#{inspect(module)} wrote a spec for #{spec.id}, not #{key}")
    else
      :unsupported -> not_supported(conn, "This server does not define agents over HTTP.")
      {:error, :conflict, message} -> conflict(conn, message)
      {:error, message} -> invalid(conn, message)
    end
  end

  defp put_agent(conn, key, spec) do
    status = if Fleet.lookup(key), do: 200, else: 201

    case Fleet.put(spec) do
      {:ok, _pid} ->
        :ok = record(conn, {:agent_defined, key})
        json(conn, status, Resource.snapshot(key, Agent.snapshot(key)))

      {:error, reason} ->
        unavailable(conn, "#{key} did not start", reason)
    end
  end

  defp definition(conn, key) do
    with {:ok, module} <- definitions(conn, :get),
         {:ok, definition} <- module.get(key) do
      json(conn, 200, definition)
    else
      :unsupported ->
        not_supported(conn, "This server does not keep agents' definitions.")

      {:error, :not_found} ->
        undefined(conn, key)
    end
  end

  defp undefined(conn, key),
    do: json(conn, 404, Resource.error("not_found", "#{key} has no definition kept."))

  # The definition module is asked first, and may refuse. An agent is
  # forgotten where the store holds one, awake or asleep.
  defp forget(conn, key) do
    with {:ok, module} <- definitions(conn, :delete),
         kept when kept in [:ok, {:error, :not_found}] <- module.delete(key) do
      held = Fleet.lookup(key)
      if held, do: :ok = Fleet.forget(key)

      if held || kept == :ok do
        :ok = record(conn, {:agent_forgotten, key})
        send_resp(conn, 204, "")
      else
        not_found(conn, key)
      end
    else
      :unsupported -> not_supported(conn, "This server does not delete agents over HTTP.")
      {:error, :conflict, message} -> conflict(conn, message)
    end
  end

  @callbacks %{put: 3, get: 1, delete: 1, put_schedule: 3, delete_schedule: 2}

  # The listener's definition module, where it has `callback`.
  defp definitions(conn, callback) do
    with module when module != nil <- conn.assigns.options[:definition],
         {:module, module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, callback, Map.fetch!(@callbacks, callback)) do
      {:ok, module}
    else
      _none -> :unsupported
    end
  end

  # Plug.Parsers keeps a body that is not an object under "_json".
  defp object(%{"_json" => _value}), do: {:error, "The body is a JSON object"}
  defp object(fields), do: {:ok, fields}

  # -- schedules -------------------------------------------------------------

  # A schedule is part of the agent's definition, so the module keeping
  # definitions sets it.
  defp schedule(conn, key, name) do
    with {:ok, module} <- definitions(conn, :put_schedule),
         {:ok, fields} <- object(conn.body_params),
         {:ok, status, schedule} <- module.put_schedule(key, name, fields) do
      :ok = record(conn, {:schedule_set, key, name})
      json(conn, if(status == :created, do: 201, else: 200), %{"schedule" => schedule})
    else
      :unsupported -> not_supported(conn, "This server does not schedule agents over HTTP.")
      {:error, :not_found} -> undefined(conn, key)
      {:error, :conflict, message} -> conflict(conn, message)
      {:error, message} -> invalid(conn, message)
    end
  end

  defp unschedule(conn, key, name) do
    with {:ok, module} <- definitions(conn, :delete_schedule),
         :ok <- module.delete_schedule(key, name) do
      :ok = record(conn, {:schedule_removed, key, name})
      send_resp(conn, 204, "")
    else
      :unsupported ->
        not_supported(conn, "This server does not schedule agents over HTTP.")

      {:error, :not_found} ->
        json(conn, 404, Resource.error("not_found", "#{key} has no schedule #{name}."))

      {:error, :conflict, message} ->
        conflict(conn, message)
    end
  end

  # -- events ----------------------------------------------------------------

  defp events(conn, key) do
    with {:ok, cursor} <- cursor(conn),
         {:ok, limit} <- limit(conn.query_params) do
      if stream?(conn),
        do: stream(conn, key, cursor || :head),
        else: page(conn, key, cursor || 0, limit)
    else
      {:error, message} -> invalid(conn, message)
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
        gone(conn, oldest)

      :not_found ->
        not_found(conn, key)

      {:error, :not_found} ->
        json(conn, 401, Resource.error("unauthorized", "The credential was revoked."))

      {:error, :unavailable} ->
        unavailable(conn, "The credential cannot be checked now", :unavailable)
    end
  end

  defp page(conn, key, starting_after, limit) do
    case Log.read(key, starting_after: starting_after, limit: limit) do
      {:ok, events} -> json(conn, 200, %{"events" => events})
      {:gap, oldest} -> gone(conn, oldest)
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

  # -- messages, decisions and cancelling -----------------------------------

  defp ask(conn, key) do
    with {:ok, id, text} <- message(conn.body_params),
         :ok <- Agent.ask(key, text, id: id) do
      json(conn, 202, %{"message" => %{"id" => id}})
    else
      {:error, :not_found} -> not_found(conn, key)
      {:error, message} -> invalid(conn, message)
    end
  end

  defp message(%{"parts" => parts} = message) when is_list(parts) do
    texts = for %{"type" => "text", "content" => text} when is_binary(text) <- parts, do: text
    identified(message, Enum.join(texts, "\n"))
  end

  defp message(%{"content" => text} = message) when is_binary(text), do: identified(message, text)
  defp message(_body), do: {:error, "A message has text parts, or content"}

  defp identified(_message, ""), do: {:error, "A message has text to send"}
  defp identified(%{"id" => id}, text) when is_binary(id) and id != "", do: {:ok, id, text}
  defp identified(%{"id" => _id}, _text), do: {:error, "A message's id is text"}
  defp identified(_message, text), do: {:ok, Wardrik.UUID.v7(), text}

  defp decide(conn, key, id) do
    with {:ok, decision} <- decision(conn.body_params),
         :ok <- Agent.decide(key, %{id => decision}, by: conn.assigns.caller.principal) do
      json(conn, 200, %{"interrupt" => %{"id" => id, "decision" => verdict(decision)}})
    else
      {:error, :not_found} ->
        not_found(conn, key)

      {:error, :not_parked} ->
        conflict(conn, "#{key} is not waiting on anything.")

      {:error, :stale_decision} ->
        conflict(conn, "#{key} is not waiting on #{id}.")

      {:error, :unrecorded} ->
        json(
          conn,
          503,
          Resource.error(
            "unavailable",
            "#{key} could not record the decision, so it was not taken."
          )
        )

      {:error, message} ->
        invalid(conn, message)
    end
  end

  # Where a person authorizes the call an interrupt waits on: only to a caller
  # that may decide it, since the link is kept out of every event.
  defp authorization(conn, key, id) do
    case Agent.parked(key) do
      {:error, :not_found} -> not_found(conn, key)
      calls -> calls |> link(id) |> authorization_answer(conn, key, id)
    end
  end

  defp link(calls, id) do
    case Enum.find(calls, fn {call, _prompt} -> call.id == id end) do
      {%{link: %{url: _url} = link}, _prompt} -> {:ok, link}
      {_call, _prompt} -> :none
      nil -> :not_waiting
    end
  end

  defp authorization_answer({:ok, link}, conn, _key, _id),
    do: json(conn, 200, Resource.authorization(link))

  defp authorization_answer(:none, conn, _key, id),
    do: json(conn, 404, Resource.error("not_found", "#{id} waits on no authorization."))

  defp authorization_answer(:not_waiting, conn, key, id),
    do: json(conn, 404, Resource.error("not_found", "#{key} is not waiting on #{id}."))

  defp decision(%{"decision" => "approve"} = body) do
    case body["note"] do
      note when is_binary(note) -> {:ok, {:approve, note}}
      _none -> {:ok, :approve}
    end
  end

  defp decision(%{"decision" => "reject"} = body) do
    case body["reason"] do
      reason when is_binary(reason) and reason != "" -> {:ok, {:deny, reason}}
      _none -> {:ok, {:deny, "Refused through the HTTP API."}}
    end
  end

  defp decision(_body), do: {:error, "decision is approve or reject"}

  defp verdict(:approve), do: "approved"
  defp verdict({:approve, _note}), do: "approved"
  defp verdict({:deny, _reason}), do: "rejected"

  defp cancel(conn, key) do
    case Agent.interrupt(key) do
      :ok ->
        :ok = record(conn, {:agent_cancelled, key})
        json(conn, 202, %{"agent" => %{"id" => to_string(key)}})

      {:error, :not_found} ->
        not_found(conn, key)
    end
  end

  defp clear(conn, key) do
    case Agent.clear(key) do
      :ok ->
        :ok = record(conn, {:agent_cleared, key})
        send_resp(conn, 204, "")

      {:error, :busy} ->
        conflict(conn, "#{key} is running a turn, or waiting on a person; cancel it, or wait")

      {:error, :not_found} ->
        not_found(conn, key)
    end
  end

  defp record(conn, action), do: Audit.record(action, conn.assigns.caller.principal)

  # -- answers ---------------------------------------------------------------

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp not_found(conn, key),
    do: json(conn, 404, Resource.error("not_found", "No agent runs under #{key}."))

  @verbs %{
    read: "read",
    message: "send messages to",
    decide: "decide the calls of",
    define: "define"
  }

  defp forbidden(conn, action, key) do
    message = "This caller may not #{Map.fetch!(@verbs, action)} #{key}."
    json(conn, 403, Resource.error("forbidden", message))
  end

  defp invalid(conn, message), do: json(conn, 400, Resource.error("invalid_request", message))

  defp internal(conn, message) do
    Logger.error(message)
    json(conn, 500, Resource.error("internal", "Something went wrong."))
  end

  defp unavailable(conn, message, reason) do
    Logger.warning("#{message}: #{inspect(reason)}")
    json(conn, 503, Resource.error("unavailable", message <> "."))
  end

  defp conflict(conn, message), do: json(conn, 409, Resource.error("conflict", message))

  defp not_supported(conn, message),
    do: json(conn, 501, Resource.error("not_supported", message))

  defp gone(conn, oldest) do
    message =
      "Events before #{oldest} have been dropped; read the snapshot and follow from its sequence."

    json(conn, 410, Resource.error("gap", message, %{"oldest" => oldest}))
  end
end
