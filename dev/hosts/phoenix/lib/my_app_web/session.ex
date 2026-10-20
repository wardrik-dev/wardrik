defmodule MyAppWeb.Session do
  @moduledoc """
  The token this app gives a user for the agents' API, signed with the
  endpoint's secret, and the user a request presents one for.
  """

  @day 86_400

  @doc "A token `user` presents as `Authorization: Bearer TOKEN`."
  def token(%MyApp.Accounts.User{} = user),
    do: Phoenix.Token.sign(MyAppWeb.Endpoint, "agents", user)

  @doc "The user `conn`'s token is for, or `:error`."
  def user(conn) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, user} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "agents", token, max_age: @day) do
      {:ok, user}
    else
      _no_session -> :error
    end
  end
end
