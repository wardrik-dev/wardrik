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

  test "schema/1 puts every reference in its place, and each input's examples hold" do
    for file <- @files,
        name = Path.basename(file, ".json"),
        String.starts_with?(name, "input_") do
      schema = WardrikProtocol.schema(name)
      refute inspect(schema) =~ "$ref"
      refute Map.has_key?(schema, "$id")

      root = JSV.build!(schema)
      for example <- schema["examples"], do: assert({:ok, _} = JSV.validate(example, root))
    end

    assert %{"properties" => %{"trigger" => %{"properties" => %{"every" => _}}}} =
             WardrikProtocol.schema("input_agent_trigger_set")
  end

  test "the schemas compiled in are what the files hold now, every reference in its place" do
    for file <- @files, name = Path.basename(file, ".json") do
      assert WardrikProtocol.Inline.schema(WardrikProtocol.dir(), name) ==
               WardrikProtocol.schema(name)
    end

    refute WardrikProtocol.__mix_recompile__?()
  end
end
