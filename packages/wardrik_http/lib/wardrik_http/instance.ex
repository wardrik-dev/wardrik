defmodule WardrikHTTP.Instance do
  @moduledoc false
  # Knows a request by what a `use Wardrik` instance's authenticate/1 says
  # of it: the user it comes from, who acts as the instance's principal/1
  # and grants/1 say, as the instance's own functions do.

  @enforce_keys [:agents]
  defstruct [:agents]

  @type t() :: %__MODULE__{agents: module()}
end

defimpl WardrikHTTP.Authenticator, for: WardrikHTTP.Instance do
  alias Wardrik.Principal

  def authenticate(%{agents: agents}, conn) do
    case agents.authenticate(conn) do
      {:ok, user} ->
        %Wardrik.Scope{token: token} = Wardrik.Instance.as(agents, user)
        id = Principal.id(token.principal)

        {:ok,
         %WardrikHTTP.Caller{id: id, name: Principal.name(token.principal) || id, token: token}}

      :error ->
        {:error, :unauthorized}
    end
  end

  def challenge(_instance), do: "Bearer"
end
