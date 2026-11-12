defmodule WardrikDaemon.Web.ConnectionSettings do
  @moduledoc false

  # Gives the dashboard's Connections page the signed-in person's accounts.

  @behaviour WardrikWeb.Connections

  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Connections
  alias WardrikDaemon.Web.Settings

  @impl true
  def list(scope, _opts) do
    with :ok <- allowed(scope, "connection.read"),
         do: {:ok, Connections.list(Settings.daemon(), scope.principal)}
  end

  @impl true
  def connect(scope, provider, _opts) do
    with :ok <- allowed(scope, "connection.connect"),
         do: Connections.connect(Settings.daemon(), scope.principal, provider)
  end

  @impl true
  def pair(scope, provider, code, _opts) do
    with :ok <- allowed(scope, "connection.connect"),
         {:ok, _connection} <-
           Connections.pair(Settings.daemon(), scope.principal, {provider, code}),
         do: :ok
  end

  @impl true
  def disconnect(scope, provider, _opts) do
    with :ok <- allowed(scope, "connection.delete"),
         do: Connections.disconnect(Settings.daemon(), scope.principal, provider)
  end

  defp allowed(scope, action),
    do: Allowed.authorized(scope, action, {:connection, scope.principal.id})
end
