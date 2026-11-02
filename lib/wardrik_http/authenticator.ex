defmodule WardrikHTTP.Authenticator do
  @moduledoc """
  A behaviour for deciding who a request comes from, as the `Wardrik.Scope` it acts in.

  Pass one as `authenticator: {module, opts}`. `WardrikHTTP.Bearer` is used unless set.

      defmodule MyAppWeb.WardrikSession do
        @behaviour WardrikHTTP.Authenticator

        @impl true
        def authenticate(%{conn: conn, server: server, wardrik: wardrik}, _opts) do
          with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
               {:ok, id} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "wardrik", token, max_age: 86_400) do
            grants = [roles: [:owner], resources: [id <> "/*"]]
            {:ok, Wardrik.Scope.new(server, wardrik: wardrik, principal: id, grants: grants)}
          else
            _not_signed_in -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
          end
        end
      end

  It's called again periodically while an event stream or worker socket is open. The connection
  closes once it returns an error.
  """

  @doc "Returns the scope the request's `conn` acts in, or an error."
  @callback authenticate(WardrikHTTP.Authenticator.Request.t(), opts :: term()) ::
              {:ok, Wardrik.Scope.t()} | {:error, Wardrik.Error.t()}
end
