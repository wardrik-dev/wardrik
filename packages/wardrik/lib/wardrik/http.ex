defmodule Wardrik.HTTP do
  @moduledoc """
  Serves every operation over HTTP, plus workers, channels and sign-in pages. See `Wardrik.HTTP.Endpoint`.

  Application integration fragment. Start the required processes before calling these functions.
  See the [package README](https://github.com/wardrik-dev/wardrik#readme) for complete setup.

      children = [
        MyApp.AgentRuntime,
        {Wardrik.HTTP,
         wardrik: MyApp.AgentRuntime, authenticator: {MyAppWeb.WardrikSession, []}, port: 4000}
      ]

  Or from your router:

      forward "/agents", Wardrik.HTTP,
        wardrik: MyApp.AgentRuntime,
        authenticator: {MyAppWeb.WardrikSession, []}

  ## Options

    * `:wardrik` - required. The module to serve, as `MyApp.AgentRuntime`.
    * `:authenticator` - required. The `Wardrik.HTTP.Authenticator` that turns requests into scopes.
    * `:principal` - `{module, function, args}` that returns who is at the browser on sign-in
      pages. Without it, no sign-in finishes.
    * `:keepalive` - see `Wardrik.HTTP.Endpoint`.

  As a child it takes Bandit's options, such as `:port`, and needs `:bandit` in your deps.
  """

  @behaviour Plug

  alias Wardrik.HTTP.Endpoint

  @doc "Returns a child spec that serves Wardrik with Bandit."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: opts |> served() |> Endpoint.child_spec()

  @doc """
  Returns a `:body_reader` for `Plug.Parsers` that keeps the raw body for webhook signatures.

      plug Plug.Parsers, parsers: [:json], json_decoder: JSON, body_reader: Wardrik.HTTP.body_reader()
  """
  @spec body_reader() :: {module(), atom(), list()}
  def body_reader, do: {Wardrik.HTTP.BodyReader, :read_body, []}

  @impl Plug
  def init(opts), do: opts |> served() |> Endpoint.init()

  @impl Plug
  def call(conn, settings), do: Endpoint.call(conn, settings)

  defp served(opts) do
    {principal, opts} = Keyword.pop(opts, :principal, {__MODULE__, :nobody, []})
    opts |> Keyword.pop(:wardrik) |> served_as(principal)
  end

  @doc false
  def nobody(_conn), do: nil

  defp served_as({wardrik, opts}, principal) when is_atom(wardrik) and not is_nil(wardrik),
    do:
      [server: {Wardrik, wardrik}, sign_in: {Wardrik, :sign_in_pages, [wardrik, principal]}] ++
        opts

  defp served_as(_none, _principal),
    do:
      raise(ArgumentError, "Wardrik.HTTP serves a Wardrik. Give it wardrik: MyApp.AgentRuntime.")
end
