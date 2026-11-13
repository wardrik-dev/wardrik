defmodule Wardrik.CatalogTest do
  use ExUnit.Case, async: true

  alias Wardrik.Catalog

  test "does every operation of the protocol, and nothing else" do
    catalog = Catalog.new()
    operations = MapSet.new(WardrikProtocol.operations(), & &1.id)

    handled = Map.keys(catalog.handlers)
    assert MapSet.new(handled) == operations
    described = Map.keys(catalog.operations)
    assert MapSet.new(described) == operations
  end

  test "streams every operation that can be streamed, and nothing else" do
    streamed =
      for %{stream: true, id: id} <- WardrikProtocol.operations(), into: MapSet.new(), do: id

    streams = Map.keys(Catalog.new().streams)
    assert MapSet.new(streams) == streamed
  end

  test "turns what a view returns into JSON" do
    assert Wardrik.JSON.json(%{
             kind: :run,
             live: false,
             at: nil,
             steps: [%{type: :text}],
             cost: 7
           }) ==
             %{
               "kind" => "run",
               "live" => false,
               "at" => nil,
               "steps" => [%{"type" => "text"}],
               "cost" => 7
             }
  end

  test "describes an error as the protocol does" do
    error = Wardrik.Error.new(:not_found, "There's no agent acme/triage.")

    assert Wardrik.Error.json(error) == %{
             "error" => %{"type" => "not_found", "message" => "There's no agent acme/triage."}
           }

    assert Exception.message(error) == "There's no agent acme/triage."
  end
end
