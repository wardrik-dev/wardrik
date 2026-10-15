defmodule MyAppWeb.Session do
  @moduledoc """
  Knows a request to the agents' API by a token this app gave its user,
  signed with the endpoint's secret.
  """

  @enforce_keys [:endpoint]
  defstruct [:endpoint]

  @doc "A token `user` presents as `Authorization: Bearer TOKEN`."
  def token(%MyApp.Accounts.User{} = user),
    do: Phoenix.Token.sign(MyAppWeb.Endpoint, "agents", user)
end

defimpl WardrikHTTP.Authenticator, for: MyAppWeb.Session do
  import Plug.Conn

  @day 86_400

  def authenticate(session, conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Phoenix.Token.verify(session.endpoint, "agents", token, max_age: @day) do
      {:ok, grant} = Wardrik.Grant.new(MyApp.Grants.own(user))

      {:ok,
       %WardrikHTTP.Caller{
         id: "session/#{user.id}",
         name: user.email,
         principal: MyApp.Grants.principal(user),
         grant: grant
       }}
    else
      _no_session -> {:error, :unauthorized}
    end
  end

  def challenge(_session), do: ~s(Bearer realm="my_app")
end
