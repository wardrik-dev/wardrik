defmodule WardrikHTTP.Authenticator.Request do
  @moduledoc """
  What `c:WardrikHTTP.Authenticator.authenticate/2` decides: who `conn` comes from, on the
  instance `wardrik`, run by the `Wardrik.Server` module `server`.

      %WardrikHTTP.Authenticator.Request{conn: conn, server: Wardrik, wardrik: MyApp.AgentRuntime}
  """

  @enforce_keys [:conn, :server, :wardrik]
  defstruct [:conn, :server, :wardrik]

  @type t() :: %__MODULE__{conn: Plug.Conn.t(), server: module(), wardrik: atom()}
end
