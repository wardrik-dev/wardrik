defmodule Wardrik.HTTP.Authenticator.Request do
  @moduledoc """
  What `c:Wardrik.HTTP.Authenticator.authenticate/2` gets: the `conn`, the `Wardrik.Server`
  module and the `wardrik` instance.

      %Wardrik.HTTP.Authenticator.Request{conn: conn, server: Wardrik, wardrik: MyApp.AgentRuntime}
  """

  @enforce_keys [:conn, :server, :wardrik]
  defstruct [:conn, :server, :wardrik]

  @type t() :: %__MODULE__{conn: Plug.Conn.t(), server: module(), wardrik: atom()}
end
