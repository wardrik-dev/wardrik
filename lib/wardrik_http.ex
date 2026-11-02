defmodule WardrikHTTP do
  @moduledoc """
  Serves Wardrik's operations over HTTP.

  Most apps use `Wardrik.HTTP`, which sets `:server` and `:sign_in` for you:

      children = [MyApp.AgentRuntime, {Wardrik.HTTP, wardrik: MyApp.AgentRuntime, port: 4000}]

  Use `WardrikHTTP` directly to serve any `Wardrik.Server`:

      children = [{WardrikHTTP, server: {Wardrik, MyApp.AgentRuntime}, port: 4000}]

  It's also a `Plug`, so your router can forward a path to it.

  ## Options

    * `:server` - required. `{module, name}`: the `Wardrik.Server` module, and the instance name
      it runs. Raises `ArgumentError` without it.
    * `:authenticator` - a `WardrikHTTP.Authenticator`, as `{module, config}`.
      `{WardrikHTTP.Bearer, []}` unless set.
    * `:sign_in` - `{module, function, args}` returning the `{plug, opts}` that serves sign-in
      pages, or `nil`. `nil` unless set.
    * `:keepalive` - milliseconds an idle event stream waits before sending a comment. `15_000`.

  As a child, it also takes Bandit's options, like `:port` and `:ip`.

  ## Routes

  | Route | Serves |
  | --- | --- |
  | each operation's route | every operation in `WardrikProtocol`, as JSON |
  | the same, with `Accept: text/event-stream` | streaming operations, as server-sent events |
  | `GET /v1/openapi.json` | the OpenAPI document |
  | `GET /v1/workers` | the tool workers' WebSocket. See `WardrikHTTP.Worker`. |
  | `POST /v1/channels/{channel}/{path}` | a chat app's request, relayed to the channel and back |
  | `/oauth/*` | sign-in pages, from `:sign_in` |

  `GET /v1/workers` returns `426` to a request with a valid token that isn't a WebSocket upgrade,
  so a worker can check its token first.

  Every response has a `request-id` header. It's the caller's own if the request sent one.
  """

  @behaviour Plug

  import Plug.Conn

  alias Wardrik.Error
  alias WardrikHTTP.Authenticator
  alias WardrikHTTP.EventStream
  alias WardrikHTTP.Input
  alias WardrikHTTP.Response
  alias WardrikHTTP.Routes

  @own [:server, :authenticator, :sign_in, :keepalive]
  @request_id Plug.RequestId.init(http_header: "request-id")

  @doc "Returns a child spec that serves with Bandit. Options not listed above go to Bandit."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    {own, bandit} = Keyword.split(opts, @own)
    Bandit.child_spec([plug: {__MODULE__, own}] ++ bandit)
  end

  @impl Plug
  def init(opts) do
    opts
    |> Keyword.validate!([
      :server,
      authenticator: {WardrikHTTP.Bearer, []},
      sign_in: nil,
      keepalive: 15_000
    ])
    |> Map.new()
    |> server!()
  end

  defp server!(%{server: {module, name}} = settings) when is_atom(module) and is_atom(name),
    do: settings

  defp server!(_settings),
    do:
      raise(
        ArgumentError,
        "WardrikHTTP serves a Wardrik. Give it server: {Wardrik, MyApp.AgentRuntime}, or use Wardrik.HTTP."
      )

  @impl Plug
  def call(conn, settings), do: conn |> Plug.RequestId.call(@request_id) |> serve(settings)

  defp serve(%Plug.Conn{method: "GET", path_info: ["v1", "openapi.json"]} = conn, _settings),
    do: Response.json(conn, 200, WardrikProtocol.openapi())

  defp serve(%Plug.Conn{method: "GET", path_info: ["v1", "workers"]} = conn, settings) do
    with {:ok, scope} <- authenticate(conn, settings),
         :ok <- upgradable(conn) do
      worker = %{scope: scope, alive?: alive?(conn, settings), keepalive: settings.keepalive}
      WebSockAdapter.upgrade(conn, WardrikHTTP.Worker, worker, [])
    else
      {:error, :upgrade_required} -> upgrade_required(conn)
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  defp serve(%Plug.Conn{path_info: ["oauth" | rest]} = conn, %{sign_in: sign_in}),
    do: sign_in(conn, rest, pages(sign_in))

  defp serve(conn, settings) do
    with {:ok, segments} <- segments(conn.path_info),
         {:ok, operation, params} <- route(conn.method, segments),
         {:ok, scope} <- authenticate(conn, operation, settings),
         {:ok, input, conn} <- Input.build(conn, operation, params) do
      respond(conn, scope, operation, input, settings)
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  defp pages(nil), do: nil
  defp pages({module, function, args}), do: apply(module, function, args)

  defp sign_in(conn, _rest, nil), do: Response.error(conn, no_route())
  defp sign_in(conn, rest, {plug, opts}), do: Plug.forward(conn, rest, plug, opts)

  defp segments(path_info) do
    decoded = Enum.map(path_info, &URI.decode/1)

    case Enum.any?(decoded, &String.contains?(&1, "/")) do
      false -> {:ok, decoded}
      true -> {:error, Error.new(:invalid_request, "A path segment can't hold a /.")}
    end
  end

  defp route(method, segments) do
    case Routes.match(method, segments) do
      {:ok, operation, params} -> {:ok, operation, params}
      :error -> {:error, no_route()}
    end
  end

  defp no_route, do: Error.new(:not_found, "There's no route here.")

  defp authenticate(_conn, %{subject: subject}, %{server: {module, wardrik}})
       when subject in ["hook", "channel"],
       do: {:ok, Wardrik.Scope.new(module, wardrik: wardrik, principal: "anonymous")}

  defp authenticate(conn, _operation, settings), do: authenticate(conn, settings)

  defp authenticate(conn, %{server: {server, wardrik}, authenticator: {module, opts}}),
    do:
      module.authenticate(
        %Authenticator.Request{conn: conn, server: server, wardrik: wardrik},
        opts
      )

  defp alive?(conn, settings), do: fn -> match?({:ok, _scope}, authenticate(conn, settings)) end

  defp upgradable(conn) do
    case WebSockAdapter.UpgradeValidation.validate_upgrade(conn) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error, :upgrade_required}
    end
  end

  defp upgrade_required(conn) do
    error = Error.new(:invalid_request, "Open /v1/workers as a WebSocket.")
    Response.json(conn, 426, Error.json(error))
  end

  defp respond(conn, scope, %{stream: true} = operation, input, settings) do
    case event_stream?(conn) do
      true -> stream(conn, scope, operation, resumed(conn, input), settings)
      false -> Response.answer(conn, operation, Wardrik.Scope.run(scope, operation.id, input))
    end
  end

  defp respond(conn, scope, %{subject: "channel"} = operation, input, _settings),
    do: Response.relay(conn, Wardrik.Scope.run(scope, operation.id, input))

  defp respond(conn, scope, operation, input, _settings),
    do: Response.answer(conn, operation, Wardrik.Scope.run(scope, operation.id, input))

  defp event_stream?(conn),
    do: conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/event-stream"))

  defp resumed(conn, input) do
    case get_req_header(conn, "last-event-id") do
      [cursor | _rest] -> Map.put_new(input, "after", cursor)
      [] -> input
    end
  end

  defp stream(conn, scope, operation, input, settings) do
    case Wardrik.Scope.stream(scope, operation.id, input) do
      {:ok, events} -> EventStream.serve(conn, events, stream_options(conn, input, settings))
      {:error, error} -> Response.error(conn, error)
    end
  end

  defp stream_options(conn, input, settings),
    do: [after: input["after"], keepalive: settings.keepalive, alive?: alive?(conn, settings)]
end
