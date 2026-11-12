defmodule WardrikHTTP.Authenticator do
  @moduledoc """
  A behaviour that turns a request into the `Wardrik.Scope` it runs in. Required.

      defmodule MyAppWeb.WardrikSession do
        @behaviour WardrikHTTP.Authenticator

        @impl true
        def authenticate(%{conn: conn, server: server, wardrik: wardrik}, _opts) do
          with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
               {:ok, id} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "wardrik", token, max_age: 86_400) do
            {:ok, Wardrik.Scope.new(server, wardrik: wardrik, principal: id)}
          else
            _not_signed_in -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
          end
        end
      end

  It runs again now and then while an event stream or worker socket is open. An error closes it.
  """

  @doc "Returns the scope the request's `conn` acts in, or an error."
  @callback authenticate(WardrikHTTP.Authenticator.Request.t(), opts :: term()) ::
              {:ok, Wardrik.Scope.t()} | {:error, Wardrik.Error.t()}
end
