defmodule WardrikDaemon.HTTPTest do
  use ExUnit.Case, async: false

  import WardrikDaemon.Test

  alias WardrikDaemon.Client

  setup context do
    context = dirs(context)
    port = free_port()

    write(context, "config.yaml", """
    org: payments
    http: {port: #{port}}
    defaults: {model: #{model()}}
    """)

    context = start_daemon(context)
    Map.put(context, :url, "http://127.0.0.1:#{port}")
  end

  defp spec_routes do
    for {path, methods} <- WardrikDaemon.HTTP.openapi()["paths"],
        {method, _operation} <- methods,
        do: {method, path}
  end

  test "serves each route its OpenAPI spec describes, and no other" do
    assert Enum.sort(WardrikDaemon.HTTP.routes()) == Enum.sort(spec_routes())

    for {_method, path} <- spec_routes() do
      assert String.starts_with?(path, ["/v1/owners/{owner}/", "/v1/tokens", "/v1/connections"])
    end
  end

  test "answers 401 on every route without a token that works", context do
    for {method, path} <- spec_routes(), secret <- [nil, "wdk_nope_nope"] do
      url =
        context.url <>
          String.replace(path, ["{owner}", "{name}", "{id}", "{provider}"], "payments")

      auth = if secret, do: [auth: {:bearer, secret}], else: []

      response =
        Req.request!(
          [method: String.to_existing_atom(method), url: url, retry: false, json: %{}] ++ auth
        )

      assert response.status == 401, "#{method} #{path}"
      assert %{"error" => %{"type" => "unauthorized"}} = response.body
      assert Req.Response.get_header(response, "www-authenticate") == ["Bearer"]
      assert [_request_id] = Req.Response.get_header(response, "request-id")
    end
  end

  test "serves Wardrik's operations beside its own", context do
    admin = %Client{url: context.url, secret: admin_secret(context)}
    assert {:ok, %{"agents" => _agents}} = Client.run(admin, "agents.list", %{})

    assert {:ok, %{"secrets" => _secrets}} =
             Client.run(admin, "secrets.list", %{"owner" => "payments"})

    assert {:error, "invalid_request", _message} =
             Client.run(admin, "secrets.list", %{"owner" => "payments/x/y"})

    response = Req.get!(context.url <> "/v1/owners/payments/nothing", retry: false)
    assert response.status == 404
    assert response.body["error"]["message"] == "There's no route here."
  end

  defp admin_secret(context) do
    {:ok, %{secret: secret}} =
      WardrikDaemon.Tokens.create(context.daemon_store,
        name: "test",
        subject: "user:admin",
        expires: DateTime.add(DateTime.utc_now(), 1, :hour)
      )

    secret
  end
end
