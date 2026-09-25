defmodule TarsHTTP.Router do
  @moduledoc """
  The HTTP API's routes; `TarsHTTP` describes what each answers.

  Every response carries a `Request-Id` header, the caller's own where it sent
  one, and the request is logged under it. Every request presents a token
  (`TarsHTTP.Auth`), and an agent outside the token's scope is answered as
  one that does not exist.
  """

  use Plug.Router
  use Plug.ErrorHandler

  alias Tars.Agent
  alias Tars.Event.Log
  alias Tars.Fleet
  alias TarsHTTP.EventStream
  alias TarsHTTP.Resource
  alias TarsHTTP.Token

  @default_limit 100
  @max_limit 500

  plug Plug.RequestId, http_header: "request-id"
  plug Plug.Logger
  plug TarsHTTP.Auth
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["*/*"]
  plug :dispatch

  get "/v1/agents" do
    agents = for member <- Fleet.list(conn.assigns.token.scope), do: Resource.agent(member)
    json(conn, 200, %{"agents" => agents})
  end

  get "/v1/agents/:org/:user/:name" do
    within(conn, [org, user, name], &snapshot(conn, &1))
  end

  get "/v1/agents/:org/:user/:name/events" do
    within(conn, [org, user, name], &events(conn, &1))
  end

  post "/v1/agents/:org/:user/:name/messages" do
    within(conn, [org, user, name], &ask(conn, &1))
  end

  post "/v1/agents/:org/:user/:name/interrupts/:id" do
    within(conn, [org, user, name], &decide(conn, &1, id))
  end

  post "/v1/agents/:org/:user/:name/cancel" do
    within(conn, [org, user, name], &cancel(conn, &1))
  end

  match _ do
    json(
      conn,
      404,
      Resource.error("not_found", "No such route: #{conn.method} #{conn.request_path}")
    )
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: %Plug.Parsers.ParseError{}}),
    do: json(conn, 400, Resource.error("invalid_request", "The body is not JSON."))

  def handle_errors(conn, _error),
    do: json(conn, conn.status, Resource.error("internal", "Something went wrong."))

  # An agent the token does not reach is one that does not exist, to the caller.
  defp within(conn, segments, fun) do
    key = Enum.join(segments, "/")

    if Token.covers?(conn.assigns.token, key), do: fun.(key), else: not_found(conn, key)
  end

  defp snapshot(conn, key) do
    case Agent.snapshot(key) do
      {:error, :not_found} -> not_found(conn, key)
      snapshot -> json(conn, 200, Resource.snapshot(key, snapshot))
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

  defp stream(conn, key, cursor) do
    case EventStream.serve(conn, key, cursor) do
      %Plug.Conn{} = conn -> conn
      {:gap, oldest} -> gone(conn, oldest)
      :not_found -> not_found(conn, key)
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
  defp identified(_message, text), do: {:ok, Tars.UUID.v7(), text}

  defp decide(conn, key, id) do
    token = conn.assigns.token
    by = %Tars.Principal{type: :token, id: token.id, name: token.name}

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

  defp invalid(conn, message), do: json(conn, 400, Resource.error("invalid_request", message))
  defp conflict(conn, message), do: json(conn, 409, Resource.error("conflict", message))

  defp gone(conn, oldest) do
    message =
      "Events before #{oldest} have been dropped; read the snapshot and follow from its sequence."

    json(conn, 410, Resource.error("gap", message, %{"oldest" => oldest}))
  end
end
