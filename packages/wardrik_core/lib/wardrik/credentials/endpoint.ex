defmodule Wardrik.Credentials.Endpoint do
  @moduledoc """
  A credential that also says where to connect. Return it from `c:Wardrik.Credentials.resolve/2`
  in place of a token when each person or agent reaches a service at an address of its own.

      {:ok,
       %Wardrik.Credentials.Endpoint{
         url: "https://mcp.example.com/tenants/acme/mcp",
         headers: %{"x-api-key" => key}
       }}

    * `url` replaces the MCP server's `url`. A server whose credential always gives one may
      leave its own out.
    * `headers` are sent along with the server's own, and replace any of the same name.
    * `token`, if given, goes in the server's `credential_header`, as a bare token does.
  """

  defstruct [:token, :url, headers: %{}]

  @type t() :: %__MODULE__{
          token: String.t() | nil,
          url: String.t() | nil,
          headers: %{optional(String.t()) => String.t()}
        }
end
