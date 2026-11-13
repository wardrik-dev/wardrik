defmodule WardrikDaemon.Web.ConnectionSettings do
  @moduledoc false

  # Gives the dashboard's Connections page the signed-in person's accounts.

  @behaviour WardrikWeb.Connections

  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Connections
  alias WardrikDaemon.Web.Settings

  @impl true
  def list(scope, _opts) do
    with {:ok, %{"connections" => connections}} <- Wardrik.run(scope, "connections.list", %{}),
         do: {:ok, connections}
  end

  @impl true
  def connect(scope, provider, _opts),
    do: Wardrik.run(scope, "connections.connect", %{"provider" => provider})

  @impl true
  def pair(scope, provider, code, _opts) do
    with :ok <- allowed(scope, "connection.connect"),
         {:ok, _connection} <-
           Connections.pair(Settings.daemon(), scope.principal, {provider, code}),
         do: :ok
  end

  @impl true
  def disconnect(scope, provider, _opts) do
    with {:ok, nil} <- Wardrik.run(scope, "connections.disconnect", %{"provider" => provider}),
         do: :ok
  end

  defp allowed(scope, action),
    do: Allowed.authorized(scope, action, {:connection, scope.principal.id})
end
