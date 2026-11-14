defmodule WardrikRest.OpenAPITest do
  use ExUnit.Case, async: true

  alias Wardrik.Context
  alias WardrikRest.API
  alias WardrikRest.OpenAPI
  alias WardrikRest.Parameter

  @path "test/fixtures/shop.openapi.yaml"

  defp spec do
    {:ok, spec} = OpenAPI.read(path: @path)
    spec
  end

  defp operation(spec, name), do: Enum.find(spec.operations, &(&1.name == name))

  defp args(operation), do: Map.new(operation.parameters, &{&1.name, &1})

  test "reads each operation, named by its id or its method and path" do
    spec = spec()

    assert spec.title == "Shop"
    assert spec.schemes == %{"bearer" => :bearer, "key" => {:query, "api_key"}}

    names =
      spec.operations
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names ==
             ["admin", "get_health", "orders_get", "orders_tags", "orders_update", "post_orders"]

    get = operation(spec, "orders_get")
    assert get.method == :get
    assert get.path == "orders/{order_id}"
    assert get.description == "Gets an order."
    assert get.security == [["bearer"], ["key"]]

    assert %{
             "order_id" => %Parameter{in: :path, required: true, schema: %{"type" => "string"}},
             "trace" => %Parameter{in: :header, required: false},
             "expand" => %Parameter{in: :query, schema: %{"type" => "array"}}
           } = args(get)

    taken = args(get)
    refute Map.has_key?(taken, "session")
    assert args(get)["order_id"].schema["description"] == "The order's ID."
    assert operation(spec, "get_health").security == [[]]
  end

  test "makes a JSON object's fields arguments, and anything else one body" do
    spec = spec()

    update = args(operation(spec, "orders_update"))
    assert %Parameter{in: :body, required: true, schema: status} = update["status"]
    assert status["enum"] == ["open", "held", "closed"]

    assert %Parameter{in: :body, required: false, schema: %{"$ref" => "Customer"}} =
             update["customer"]

    assert %Parameter{in: :path} = update["order_id"]

    tags = operation(spec, "orders_tags")
    assert tags.encoding == :json

    assert [%Parameter{name: "body", in: :payload, required: false, schema: %{"type" => "array"}}] =
             Enum.filter(tags.parameters, &(&1.in == :payload))
  end

  test "reads form bodies, nullable types and read-only fields, and leaves out what it can't send" do
    spec = spec()
    place = operation(spec, "post_orders")

    assert place.encoding == :form
    assert place.security == [["bearer"]]
    assert %{"lines" => %{required: true}, "note" => note} = args(place)
    assert note.schema == %{"type" => "string"}
    taken = args(place)
    refute Map.has_key?(taken, "id")

    # The receipt takes only a file upload. Admin signs in only with HTTP basic, which isn't read.
    refute operation(spec, "orders_receipt")
    assert operation(spec, "admin").security == []

    assert API.load({OpenAPI, path: @path},
             name: "shop",
             base_url: "https://shop.test",
             auth: %{"bearer" => {:key, "SHOP"}},
             only: ["admin"]
           ) ==
             {:error,
              "auth gives no way to sign in to admin. Each needs a scheme wardrik_rest can't send."}

    assert spec.types["Customer"]["properties"]["referrer"] == %{"$ref" => "Customer"}
    assert spec.types["OrderChange"]["required"] == ["status"]
  end

  test "reads JSON and YAML from a url, and says why it can't read a document" do
    yaml = File.read!(@path)
    Req.Test.stub(__MODULE__.Yaml, &Plug.Conn.send_resp(&1, 200, yaml))
    Req.Test.stub(__MODULE__.Json, &Req.Test.json(&1, %{"swagger" => "2.0"}))
    Req.Test.stub(__MODULE__.Missing, &Plug.Conn.send_resp(&1, 404, "no"))
    Req.Test.stub(__MODULE__.Junk, &Plug.Conn.send_resp(&1, 200, "a: [b"))
    Req.Test.stub(__MODULE__.Down, &Req.Test.transport_error(&1, :econnrefused))
    url = "https://specs.test/shop"
    read = &OpenAPI.read(url: url, req_options: [plug: {Req.Test, &1}])

    assert {:ok, %{title: "Shop"}} = read.(__MODULE__.Yaml)

    assert read.(__MODULE__.Json) ==
             {:error, "It's OpenAPI 2 (Swagger); convert it to OpenAPI 3 first."}

    assert read.(__MODULE__.Missing) == {:error, "#{url} answered 404."}
    assert read.(__MODULE__.Junk) == {:error, "#{url} is neither JSON nor YAML."}
    assert {:error, "https://specs.test/shop didn't answer: " <> _why} = read.(__MODULE__.Down)

    assert OpenAPI.read(document: %{"openapi" => "2.5"}) ==
             {:error, "It isn't an OpenAPI 3 document."}

    assert {:error, "nowhere.yaml can't be read: " <> _why} = OpenAPI.read(path: "nowhere.yaml")
  end

  describe "a call" do
    setup %{test: test} do
      {:ok, api} =
        API.load({OpenAPI, path: @path},
          name: "shop",
          base_url: "https://shop.test/v1",
          auth: %{"bearer" => {:key, "SHOP"}},
          req_options: [plug: {Req.Test, test}]
        )

      context =
        Context.new(
          agent_id: "acme/shop",
          principal: %Wardrik.Principal{id: "org:acme"},
          keys: {WardrikRest.Test.Keys, %{"SHOP" => "s3cret"}}
        )

      pid = self()

      Req.Test.stub(test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        type =
          conn
          |> Plug.Conn.get_req_header("content-type")
          |> List.first()

        send(pid, {:called, conn.method, conn.request_path, type, body, conn.req_headers})
        Req.Test.json(conn, %{"ok" => true})
      end)

      listed = WardrikRest.tools(nil, apis: [api])
      tools = Map.new(listed, &{&1.name, &1})
      %{tools: tools, context: context}
    end

    test "sends a form body nested, with brackets", %{tools: tools, context: context} do
      args = %{
        "lines" => [%{"sku" => "beans", "quantity" => 2}],
        "shipping" => %{"name" => "Ana", "address" => %{"city" => "Lisbon"}},
        "note" => nil
      }

      assert {:ok, %{"ok" => true}} = tools["shop__post_orders"].run.(args, context)

      assert_received {:called, "POST", "/v1/orders", "application/x-www-form-urlencoded", body,
                       headers}

      assert {"authorization", "Bearer s3cret"} in headers

      assert URI.decode_query(body) == %{
               "lines[0][quantity]" => "2",
               "lines[0][sku]" => "beans",
               "shipping[address][city]" => "Lisbon",
               "shipping[name]" => "Ana"
             }
    end

    test "sends a body that isn't an object whole", %{tools: tools, context: context} do
      assert {:ok, _answer} =
               tools["shop__orders_tags"].run.(%{"order_id" => "o1", "body" => ["gift"]}, context)

      assert_received {:called, "PUT", "/v1/orders/o1/tags", "application/json", "[\"gift\"]",
                       _headers}
    end

    test "names a nested object written in place by its path, for describe", %{tools: tools} do
      {:ok, api} =
        API.load({OpenAPI, path: @path},
          name: "shop",
          base_url: "https://shop.test/v1",
          auth: %{"bearer" => {:key, "SHOP"}},
          max_schema_bytes: 300
        )

      tools = Map.merge(tools, Map.new(WardrikRest.tools(nil, apis: [api]), &{&1.name, &1}))
      shipping = tools["shop__post_orders"].schema["properties"]["shipping"]

      assert shipping["description"] == "Where it goes."

      assert [%{"description" => named}, %{"enum" => [""]}] = shipping["anyOf"]

      assert named ==
               ~s(An object; shop__describe gives its fields as "shop__post_orders/shipping".)

      describe = tools["shop__describe"]

      assert {:ok, %{"properties" => %{"address" => address, "name" => %{"type" => "string"}}}} =
               describe.run.(%{"type" => "shop__post_orders/shipping"}, nil)

      assert address["description"] =~ ~s(as "shop__post_orders/shipping/address")

      assert {:ok, %{"properties" => %{"city" => _city}}} =
               describe.run.(%{"type" => "shop__post_orders/shipping/address"}, nil)

      assert {:ok, %{"properties" => %{"referrer" => referrer}}} =
               describe.run.(%{"type" => "Customer"}, nil)

      assert referrer["description"] == "A Customer, as above."

      assert {:error, "shop has no type shop__post_orders/nothing." <> _names} =
               describe.run.(%{"type" => "shop__post_orders/nothing"}, nil)
    end
  end

  test "adds schemes a description doesn't name, tried first on every operation" do
    document = %{
      "openapi" => "3.0.3",
      "info" => %{"title" => "Plain"},
      "paths" => %{"/me" => %{"get" => %{"operationId" => "me"}}}
    }

    {:ok, api} =
      API.load({OpenAPI, document: document},
        name: "plain",
        base_url: "https://plain.test",
        schemes: %{"token" => :bearer},
        auth: %{"token" => {:key, "PLAIN"}}
      )

    assert [%{security: [["token"], []]}] = api.operations
    assert API.security(api, hd(api.operations)) == {:ok, ["token"]}

    assert API.load({OpenAPI, document: document},
             name: "plain",
             base_url: "https://plain.test",
             schemes: %{"token" => :cookie}
           ) == {:error, "schemes.token is :bearer, {:header, name} or {:query, name}."}
  end
end
