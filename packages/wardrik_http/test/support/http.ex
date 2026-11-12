defmodule WardrikHTTP.Test do
  @moduledoc "Serves a test's own server over HTTP, and asks it as a client would."

  import Plug.Conn
  import Plug.Test

  def settings(context, opts \\ []),
    do:
      WardrikHTTP.init(
        [
          server: {WardrikTesting.Server, context.name},
          authenticator: {WardrikHTTP.Test.Authenticator, []}
        ] ++ opts
      )

  def start(name, secrets) do
    :ok = WardrikTesting.Server.start(name)
    WardrikHTTP.Test.Authenticator.start(name, secrets)
  end

  def request(context, method, path, body \\ nil, headers \\ []) do
    method
    |> conn(path, encoded(body))
    |> put_req_header("authorization", "Bearer " <> context.secret)
    |> put_req_header("content-type", "application/json")
    |> merge_req_headers(headers)
    |> WardrikHTTP.call(settings(context))
  end

  def body(conn), do: JSON.decode!(conn.resp_body)

  defp encoded(nil), do: ""
  defp encoded(body) when is_binary(body), do: body
  defp encoded(body), do: JSON.encode!(body)
end
