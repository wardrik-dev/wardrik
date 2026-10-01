defmodule WardrikHTTP.Router do
  @moduledoc """
  The HTTP API's routes; `WardrikHTTP` describes what each answers.

  Every response carries a `Request-Id` header, the caller's own where it sent
  one, and the request is logged under it. Every request presents a token
  (`WardrikHTTP.Auth`), and each route asks `Wardrik.Access.authorize/3` for the
  action it takes: an agent outside the token's scope is answered as one that
  does not exist, `404`, and one inside it the token may not act on so,
  `403`. A stream of events, and a worker's socket, hold their token, and end
  when it is revoked.

  Its options are the `WardrikHTTP.Listener`'s `:definition`, assigned to each
  request as `:options`.
  """

  use Plug.Router, copy_opts_to_assign: :options
  use Plug.ErrorHandler

  require Logger

  alias Wardrik.Access
  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.Event.Log
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member
  alias Wardrik.Grant
  alias Wardrik.Schedule
  alias WardrikHTTP.EventStream
  alias WardrikHTTP.Resource
  alias WardrikHTTP.Token

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
    serves? = :serve in conn.assigns.token.grant.can

    case WebSockAdapter.UpgradeValidation.validate_upgrade(conn) do
      :ok when not serves? ->
        json(conn, 403, Resource.error("forbidden", "This token may not offer tools."))

      :ok ->
        conn
        |> WebSockAdapter.upgrade(WardrikHTTP.Worker, conn.assigns.token, timeout: @idle)
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_header("upgrade", "websocket")
        |> json(426, Resource.error("upgrade_required", "/v1/workers is a WebSocket."))
    end
  end

  get "/v1/agents" do
    token = conn.assigns.token

    agents =
      for member <- Fleet.list(token.grant.scope),
          Access.authorize(token.grant, :read, member.key) == :ok,
          do: Resource.agent(member)

    json(conn, 200, %{"agents" => agents})
  end

  # An agent is /v1/agents/{org}/{name}, or /v1/agents/{org}/@{user}/{name}
  # for a user's, and what follows its key is what is asked of it.
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

  # The segments of the key at the front of an agent's path, and the rest.
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
  defp route("PUT", ["schedules", schedule]), do: {:define, &schedule(&1, &2, schedule)}
  defp route("DELETE", ["schedules", schedule]), do: {:define, &unschedule(&1, &2, schedule)}
  defp route(_method, _rest), do: nil

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: %Plug.Parsers.ParseError{}}),
    do: json(conn, 400, Resource.error("invalid_request", "The body is not JSON."))

  def handle_errors(conn, _error),
    do: json(conn, conn.status, Resource.error("internal", "Something went wrong."))

  # A path segment is one segment of the key: one that decodes to a "/" is
  # refused. An agent the token does not reach is one that does not exist,
  # to the caller.
  defp within(conn, segments, action, fun) do
    key = Enum.join(segments, "/")

    case {Enum.find(segments, &String.contains?(&1, "/")), Fleet.cast(key)} do
      {nil, {:ok, _parts}} ->
        case Access.authorize(conn.assigns.token.grant, action, key) do
          :ok -> fun.(key)
          {:error, :forbidden} -> forbidden(conn, action, key)
          {:error, :not_found} -> not_found(conn, key)
        end

      {nil, :error} ->
        invalid(conn, "#{key} is not an agent key; a key is org/name or org/@user/name")

      {segment, _key} ->
        invalid(
          conn,
          "#{inspect(segment)} holds a /; a key's org, user and name are a path segment each"
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
         {:ok, spec} <- module.put(key, fields) do
      if Spec.key(spec) == key,
        do:
          put_agent(conn, key, %{spec | hooks: Grant.held(conn.assigns.token.grant, spec.hooks)}),
        else: internal(conn, "#{inspect(module)} wrote a spec for #{Spec.key(spec)}, not #{key}")
    else
      :unsupported -> not_supported(conn, "This server does not define agents over HTTP.")
      {:error, :conflict, message} -> conflict(conn, message)
      {:error, message} -> invalid(conn, message)
    end
  end

  defp put_agent(conn, key, spec) do
    status = if Fleet.lookup(key), do: 200, else: 201

    case Fleet.put(spec) do
      {:ok, _pid} -> json(conn, status, Resource.snapshot(key, Agent.snapshot(key)))
      {:error, reason} -> unavailable(conn, "#{key} did not start", reason)
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
        json(conn, 404, Resource.error("not_found", "#{key} has no definition kept."))
    end
  end

  # The definition module is asked first, and may refuse. An agent is
  # forgotten only where one runs, as every other route acts on running
  # agents alone.
  defp forget(conn, key) do
    with {:ok, module} <- definitions(conn, :delete),
         kept when kept in [:ok, {:error, :not_found}] <- module.delete(key) do
      running = Fleet.lookup(key)
      if running, do: :ok = Fleet.forget(key)

      if running || kept == :ok, do: send_resp(conn, 204, ""), else: not_found(conn, key)
    else
      :unsupported -> not_supported(conn, "This server does not delete agents over HTTP.")
      {:error, :conflict, message} -> conflict(conn, message)
    end
  end

  @callbacks %{put: 2, get: 1, delete: 1}

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

  defp schedule(conn, key, name) do
    with %Member{} <- Fleet.lookup(key),
         {:ok, fields} <- object(conn.body_params),
         {:ok, schedule} <- Schedule.decode(name, fields) do
      status = if scheduled?(key, name), do: 200, else: 201

      case Schedule.put(key, schedule) do
        {:ok, _pid} -> json(conn, status, %{"schedule" => Resource.schedule(schedule)})
        {:error, reason} -> unavailable(conn, "#{key}'s schedule #{name} did not start", reason)
      end
    else
      nil -> not_found(conn, key)
      {:error, message} -> invalid(conn, message)
    end
  end

  defp unschedule(conn, key, name) do
    if scheduled?(key, name) do
      :ok = Schedule.delete(key, name)
      send_resp(conn, 204, "")
    else
      json(conn, 404, Resource.error("not_found", "#{key} has no schedule #{name}."))
    end
  end

  defp scheduled?(key, name), do: Enum.any?(Schedule.for_agent(key), &(&1.name == name))

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

  # The stream holds its token while it runs, so revoking the token ends it.
  defp stream(conn, key, cursor) do
    Token.ref(conn.assigns.token)
    |> Access.holding(fn -> EventStream.serve(conn, key, cursor) end)
    |> case do
      %Plug.Conn{} = conn ->
        conn

      {:gap, oldest} ->
        gone(conn, oldest)

      :not_found ->
        not_found(conn, key)

      {:error, :not_found} ->
        json(conn, 401, Resource.error("unauthorized", "The token was revoked."))

      {:error, :unavailable} ->
        unavailable(conn, "The token cannot be checked now", :unavailable)
    end
  end

  defp page(conn, key, starting_after, limit) do
    case Log.read(key, starting_after: starting_after, limit: limit) do
      {:ok, events} -> json(conn, 200, %{"events" => events})
      {:gap, oldest} -> gone(conn, oldest)
    end
  end

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
    token = conn.assigns.token
    by = %Wardrik.Principal{type: :token, id: token.id, name: token.name}

    with {:ok, decision} <- decision(conn.body_params),
         :ok <- Agent.decide(key, %{id => decision}, by: by) do
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

  # Where a person authorizes the call an interrupt waits on: only to a token
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

  defp decision(%{"decision" => "approve"}), do: {:ok, :approve}

  defp decision(%{"decision" => "reject"} = body) do
    case body["reason"] do
      reason when is_binary(reason) and reason != "" -> {:ok, {:deny, reason}}
      _none -> {:ok, {:deny, "Refused through the HTTP API."}}
    end
  end

  defp decision(_body), do: {:error, "decision is approve or reject"}

  defp verdict(:approve), do: "approved"
  defp verdict({:deny, _reason}), do: "rejected"

  defp cancel(conn, key) do
    case Agent.interrupt(key) do
      :ok -> json(conn, 202, %{"agent" => %{"id" => key}})
      {:error, :not_found} -> not_found(conn, key)
    end
  end

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
    message = "This token may not #{Map.fetch!(@verbs, action)} #{key}."
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
