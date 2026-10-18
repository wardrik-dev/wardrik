defmodule WardrikProtocol.OpenAPITest do
  use ExUnit.Case, async: true

  alias WardrikProtocol.OpenAPI

  defp bundled, do: Path.join(Path.dirname(WardrikProtocol.openapi()), "openapi.bundled.json")

  test "the bundle is openapi.json as it is now; mix wardrik_protocol.bundle writes it again" do
    assert bundled() |> File.read!() |> JSON.decode!() == OpenAPI.bundle()
    assert :ok = Mix.Tasks.WardrikProtocol.Bundle.run(["--check"])
  end

  test "the bundle names nothing outside itself" do
    refs = bundled() |> File.read!() |> then(&Regex.scan(~r/"\$ref":\s*"([^"]*)"/, &1))
    assert [_ | _] = refs
    assert Enum.all?(refs, fn [_whole, ref] -> String.starts_with?(ref, "#/") end)
  end

  test "each schema is the component of its file's name" do
    assert OpenAPI.name("agent_snapshot") == "AgentSnapshot"
    assert OpenAPI.name("message.created") == "MessageCreated"
  end
end
