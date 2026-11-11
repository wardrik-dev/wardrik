defmodule WardrikDaemon.Web.Resolver do
  @moduledoc false
  @behaviour WardrikWeb.Resolver

  alias Wardrik.Error
  alias WardrikDaemon.Authenticator
  alias WardrikWeb.Resolver.Request

  @impl true
  def scope(%Request{session: %{"wardrik_token" => secret}, endpoint: endpoint}, _opts) do
    %{store: store, wardrik: wardrik} = endpoint.config(:daemon)

    case Authenticator.for_secret(store, wardrik, secret) do
      {:ok, scope} -> {:ok, scope}
      :error -> signed_out()
    end
  end

  def scope(_request, _opts), do: signed_out()

  defp signed_out, do: {:error, Error.new(:unauthorized, "Sign in with wardrik web.")}
end
