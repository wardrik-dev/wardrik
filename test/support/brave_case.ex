defmodule WardrikBrave.Case do
  @moduledoc """
  Case template for the Brave client.

  Requests are routed to a `Req.Test` stub through `Config.req_options`, so
  every client function runs its real request building and response matching
  without touching the network. `Req.Test` stubs are per-test, so cases can run
  async.

  Every stub reports its `%Plug.Conn{}` and raw body to the test process, so a
  test can `assert_receive {:req, conn, body}` to check what went out.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import WardrikBrave.Case

      alias WardrikBrave.Config
    end
  end

  @stub WardrikBrave.Stub

  @doc "Answers every request with `body` as JSON under `status`."
  def stub_json(status, body) do
    stub_with(fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end)
  end

  @doc "Answers with `status` and no body worth reading."
  def stub_status(status) do
    stub_with(fn conn -> Plug.Conn.resp(conn, status, "") end)
  end

  @doc "Answers with `plug`, a `fun(conn)` returning a conn."
  def stub_with(plug) when is_function(plug, 1) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      body = Req.Test.raw_body(conn)
      send(test, {:req, conn, body})
      plug.(conn)
    end)
  end

  @doc "A reported request's JSON body, decoded."
  def sent_body(body) when is_binary(body) and body != "", do: JSON.decode!(body)
  def sent_body(_body), do: nil
end
