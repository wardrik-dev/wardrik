defmodule MyAppWeb.OAuthController do
  use MyAppWeb, :controller

  def callback(conn, %{"provider" => provider, "state" => state, "code" => code} = params) do
    case WardrikOAuth.finish(state, code, provider: provider, iss: params["iss"]) do
      {:ok, _provider} ->
        text(conn, "Connected. Go back to your agent.")

      {:error, _reason} ->
        conn |> put_status(400) |> text("That sign-in did not finish. Open its link again.")
    end
  end

  def callback(conn, _params),
    do: conn |> put_status(400) |> text("This is where a sign-in comes back to.")
end
