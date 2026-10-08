defmodule WardrikProtocolTest do
  use ExUnit.Case, async: true

  @files WardrikProtocol.dir() |> Path.join("*.json") |> Path.wildcard()

  test "each schema's $id is its file's name, and every reference in it resolves" do
    assert [_ | _] = @files

    for file <- @files do
      id = "urn:wardrik:schema:v1:" <> Path.basename(file, ".json")

      assert %{"$id" => ^id} = file |> File.read!() |> JSON.decode!()
      assert %JSV.Root{} = JSV.build!(%{"$ref" => id}, resolver: WardrikProtocol.Resolver)
    end
  end
end
