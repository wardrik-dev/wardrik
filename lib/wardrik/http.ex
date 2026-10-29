defmodule Wardrik.HTTP do
  @moduledoc """
  Serves a Wardrik over HTTP: every operation at its route, the operations that stream as
  server-sent events, tool workers' WebSocket at `/v1/workers`, chat apps' requests to its
  channels, and the pages its sign-ins come back to. See `WardrikHTTP` for the routes.

      children = [MyApp.Wardrik, {Wardrik.HTTP, wardrik: MyApp.Wardrik, port: 4000}]

  It's a `Plug` too, for your app's router to forward a path to:

      forward "/agents", Wardrik.HTTP, wardrik: MyApp.Wardrik

  It takes `:wardrik`, the instance it serves, `:authenticator` and `:keepalive` as `WardrikHTTP`
  does, and, as a child, Bandit's options, like `:port`. Serving it as a child needs `:bandit`
  among your app's dependencies.
  """

  @behaviour Plug

  @doc "Returns a child spec that serves the Wardrik with Bandit."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: opts |> served() |> WardrikHTTP.child_spec()

  @doc """
  Returns the body reader `Plug.Parsers` takes as `:body_reader`, so a webhook's body is checked as
  it came where your app parses bodies first.

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
    do: raise(ArgumentError, "Wardrik.HTTP serves a Wardrik. Give it wardrik: MyApp.Wardrik.")
end
