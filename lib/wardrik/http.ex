defmodule Wardrik.HTTP do
  @moduledoc """
  Serves Wardrik over HTTP. See `WardrikHTTP` for the routes.

  It serves:

    * every operation at its route
    * streaming operations as server-sent events
    * the tool workers' WebSocket at `/v1/workers`
    * chat apps' requests to channels
    * sign-in callback pages

  Run it as a child, with Bandit:

      children = [MyApp.AgentRuntime, {Wardrik.HTTP, wardrik: MyApp.AgentRuntime, port: 4000}]

  Or forward to it from your router, as a `Plug`:

      forward "/agents", Wardrik.HTTP, wardrik: MyApp.AgentRuntime

  ## Options

    * `:wardrik` - required. The module to serve, as `MyApp.AgentRuntime`.
    * `:authenticator` - see `WardrikHTTP`.
    * `:keepalive` - see `WardrikHTTP`.

  As a child it also takes Bandit's options, such as `:port`. That needs `:bandit` in your deps.
  """

  @behaviour Plug

  @doc "Returns a child spec that serves Wardrik with Bandit."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: opts |> served() |> WardrikHTTP.child_spec()

  @doc """
  Returns a `:body_reader` for `Plug.Parsers`.

  Use it if your app parses bodies before Wardrik. It keeps the raw body so webhook signatures
  can still be checked.

      plug Plug.Parsers, parsers: [:json], json_decoder: JSON, body_reader: Wardrik.HTTP.body_reader()
  """
  @spec body_reader() :: {module(), atom(), list()}
  def body_reader, do: {WardrikHTTP.BodyReader, :read_body, []}

  @impl Plug
  def init(opts), do: opts |> served() |> WardrikHTTP.init()

  @impl Plug
  def call(conn, settings), do: WardrikHTTP.call(conn, settings)

  defp served(opts), do: opts |> Keyword.pop(:wardrik) |> served_as()

  defp served_as({wardrik, opts}) when is_atom(wardrik) and not is_nil(wardrik),
    do: [server: {Wardrik, wardrik}, sign_in: {Wardrik, :sign_in_pages, [wardrik]}] ++ opts

  defp served_as(_none),
    do:
      raise(ArgumentError, "Wardrik.HTTP serves a Wardrik. Give it wardrik: MyApp.AgentRuntime.")
end
