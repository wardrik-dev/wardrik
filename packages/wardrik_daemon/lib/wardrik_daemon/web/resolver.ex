defmodule WardrikDaemon.Web.Resolver do
  @moduledoc false
  @behaviour WardrikWeb.Resolver

  alias Wardrik.Error
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Authenticator
  alias WardrikWeb.Resolver.Request

  @impl true
  def scope(%Request{session: %{"wardrik_token" => secret}, endpoint: endpoint}, _opts) do
    %{store: store, wardrik: wardrik} = daemon = endpoint.config(:daemon)

    case Authenticator.for_secret(store, wardrik, secret) do
      {:ok, scope} ->
        :ok = WardrikDaemon.Web.renew(daemon, secret)
        {:ok, scope}

      :error ->
        sign_out()
    end
  end

  def scope(_request, _opts), do: sign_out()

  @impl true
  def names(%Request{endpoint: endpoint}, ids, _opts) do
    %{store: store} = endpoint.config(:daemon)

    for id <- ids,
        {:ok, record} <- [AgentRecords.fetch(store, id)],
        into: %{},
        do: {id, record.name}
  end

  defp sign_out, do: {:error, Error.new(:unauthorized, "Sign in with wardrik web.")}
end
