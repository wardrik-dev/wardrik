defmodule WardrikRest.DiscoveryTest do
  use ExUnit.Case, async: true

  alias WardrikRest.Discovery
  alias WardrikRest.Parameter

  @analytics "test/fixtures/analyticsdata-v1beta.json" |> File.read!() |> JSON.decode!()

  defp read(document), do: WardrikRest.Reader.read(%Discovery{document: document})

  defp operation(spec, name), do: Enum.find(spec.operations, &(&1.name == name))

  test "reads every method of Google Analytics Data as an operation" do
    {:ok, spec} = read(@analytics)

    assert spec.title == "Google Analytics Data API"
    assert Enum.count(spec.operations) == 11
    assert spec.schemes == %{"oauth2" => :bearer, "key" => {:query, "key"}}

    report = operation(spec, "properties_runReport")
    assert report.method == :post
    assert report.path == "v1beta/{+property}:runReport"
    assert report.security == [["oauth2"], ["key"]]

    assert %Parameter{in: :path, required: true, reserved: true} =
             Enum.find(report.parameters, &(&1.name == "property"))

    body = for %{in: :body, name: name} <- report.parameters, do: name
    assert "dimensions" in body and "metrics" in body and "dateRanges" in body
    refute "property" in body
  end

  test "keeps schemas as types, referred to by name, with their fields' descriptions" do
    {:ok, spec} = read(@analytics)
    report = operation(spec, "properties_runReport")
    filter = Enum.find(report.parameters, &(&1.name == "dimensionFilter")).schema

    assert %{"$ref" => "FilterExpression", "description" => "Dimension filters" <> _rest} = filter

    assert %{"properties" => %{"andGroup" => %{"$ref" => "FilterExpressionList"}}} =
             spec.types["FilterExpression"]

    assert spec.types["FilterExpressionList"]["properties"]["expressions"] == %{
             "type" => "array",
             "description" => "A list of filter expressions.",
             "items" => %{"$ref" => "FilterExpression"}
           }
  end

  test "shortens Google's long type names where they stay unique, and drops placeholder enums" do
    {:ok, spec} =
      read(%{
        "kind" => "discovery#restDescription",
        "name" => "ads",
        "schemas" => %{
          "Ads__Campaign" => %{
            "properties" => %{
              "status" => %{"type" => "string", "enum" => ["UNSPECIFIED", "UNKNOWN", "PAUSED"]},
              "shopping" => %{"$ref" => "Ads_Campaign_ShoppingSetting"},
              "kind" => %{"type" => "string", "enum" => ["UNKNOWN"]}
            }
          },
          "Ads_Campaign_ShoppingSetting" => %{"type" => "object"},
          "Ads__Label" => %{"type" => "object"},
          "Other__Label" => %{"type" => "object"}
        }
      })

    assert Map.keys(spec.types) |> Enum.sort() ==
             ["Ads__Label", "Campaign", "Campaign_ShoppingSetting", "Other__Label"]

    assert spec.types["Campaign"]["properties"] == %{
             "status" => %{"type" => "string", "enum" => ["PAUSED"]},
             "shopping" => %{"$ref" => "Campaign_ShoppingSetting"},
             "kind" => %{"type" => "string", "enum" => ["UNKNOWN"]}
           }
  end

  test "reads a service path, repeated parameters, read-only fields and methods without scopes" do
    {:ok, spec} =
      read(%{
        "kind" => "discovery#restDescription",
        "name" => "notes",
        "servicePath" => "notes/v1/",
        "schemas" => %{
          "Note" => %{
            "properties" => %{
              "id" => %{"type" => "string", "readOnly" => true},
              "text" => %{"type" => "string"},
              "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
              "extra" => %{"type" => "object", "additionalProperties" => %{"type" => "any"}}
            }
          }
        },
        "resources" => %{
          "notes" => %{
            "methods" => %{
              "list" => %{
                "id" => "notes.notes.list",
                "httpMethod" => "GET",
                "path" => "notes",
                "parameters" => %{
                  "tag" => %{"type" => "string", "location" => "query", "repeated" => true}
                }
              },
              "create" => %{
                "id" => "notes.notes.create",
                "httpMethod" => "POST",
                "path" => "notes",
                "description" => "Makes a note.",
                "request" => %{"$ref" => "Note"}
              }
            }
          }
        }
      })

    assert spec.title == "notes"
    assert spec.schemes == %{}

    list = operation(spec, "notes_list")
    assert list.path == "notes/v1/notes"
    assert list.security == [[]]
    assert list.description == "notes.notes.list"

    assert [
             %Parameter{
               in: :query,
               schema: %{"type" => "array", "items" => %{"type" => "string"}}
             }
           ] = list.parameters

    create = operation(spec, "notes_create")
    fields = Map.new(create.parameters, &{&1.name, &1.schema})
    assert Map.keys(fields) |> Enum.sort() == ["extra", "tags", "text"]
    assert fields["extra"] == %{"type" => "object", "additionalProperties" => %{}}
  end

  test "refuses what isn't a Discovery document" do
    assert {:error, "It isn't a Discovery document."} = read(%{"openapi" => "3.1.0"})
  end

  describe "fetch/2" do
    test "fetches a Discovery document" do
      Req.Test.stub(__MODULE__.Fetch, &Req.Test.json(&1, @analytics))

      assert {:ok, %Discovery{document: %{"name" => "analyticsdata"}}} =
               Discovery.fetch("https://discovery.test/rest",
                 req_options: [plug: {Req.Test, __MODULE__.Fetch}]
               )
    end

    test "says why it can't" do
      Req.Test.stub(__MODULE__.Other, &Req.Test.json(&1, %{"openapi" => "3.1.0"}))
      Req.Test.stub(__MODULE__.Missing, &Plug.Conn.send_resp(&1, 404, "no"))
      Req.Test.stub(__MODULE__.Down, &Req.Test.transport_error(&1, :econnrefused))

      fetch = fn stub ->
        Discovery.fetch("https://discovery.test/rest", req_options: [plug: {Req.Test, stub}])
      end

      assert fetch.(__MODULE__.Other) ==
               {:error, "https://discovery.test/rest isn't a Discovery document."}

      assert fetch.(__MODULE__.Missing) == {:error, "https://discovery.test/rest answered 404."}

      assert {:error, "https://discovery.test/rest didn't answer: " <> _why} =
               fetch.(__MODULE__.Down)
    end
  end
end
