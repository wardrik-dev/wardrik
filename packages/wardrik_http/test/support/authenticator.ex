defmodule WardrikHTTP.Test.Authenticator do
  @moduledoc "Takes the secrets a test gives it as `Authorization: Bearer`, each as `acme/@maria`, until one is revoked."

  @behaviour WardrikHTTP.Authenticator

  import Plug.Conn, only: [get_req_header: 2]

  alias Wardrik.Error

  def start(name, secrets) do
    held = secrets(name)

    ExUnit.Callbacks.start_supervised!(%{
      id: held,
      start: {Agent, :start_link, [fn -> MapSet.new(secrets) end, [name: held]]}
    })

    :ok
  end

  def revoke(name, secret), do: Agent.update(secrets(name), &MapSet.delete(&1, secret))

  @impl WardrikHTTP.Authenticator
  def authenticate(%{conn: conn, server: server, wardrik: wardrik}, _opts) do
    with ["Bearer " <> secret] <- get_req_header(conn, "authorization"),
         true <- Agent.get(secrets(wardrik), &MapSet.member?(&1, secret)) do
      {:ok, Wardrik.Scope.new(server, wardrik: wardrik, principal: "acme/@maria")}
    else
      _unknown -> {:error, Error.new(:unauthorized, "Sign in first.")}
    end
  end

  defp secrets(name), do: Module.concat(name, Secrets)
end
