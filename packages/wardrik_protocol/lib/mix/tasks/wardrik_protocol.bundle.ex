defmodule Mix.Tasks.WardrikProtocol.Bundle do
  @shortdoc "Writes priv/openapi.bundled.json from openapi.json and the schemas"

  @moduledoc """
  Writes `priv/openapi.bundled.json`, `openapi.json` with every schema it
  reaches among its components, as `WardrikProtocol.OpenAPI.bundle/1` makes
  it. Run it after changing either.

      mix wardrik_protocol.bundle           write it
      mix wardrik_protocol.bundle --check   fail where it is not what it would write
  """

  use Mix.Task

  @priv "priv"
  @bundled Path.join(@priv, "openapi.bundled.json")

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [check: :boolean])
    bundled = @priv |> WardrikProtocol.OpenAPI.bundle() |> pretty("") |> IO.iodata_to_binary()

    cond do
      opts[:check] != true -> File.write!(@bundled, [bundled, "\n"])
      File.read(@bundled) == {:ok, bundled <> "\n"} -> :ok
      true -> Mix.raise("#{@bundled}: not what mix wardrik_protocol.bundle writes; run it")
    end
  end

  # JSON two spaces deep, keys sorted, so the file changes only as the
  # document does.
  defp pretty(map, _indent) when map == %{}, do: "{}"

  defp pretty(map, indent) when is_map(map) do
    inner = indent <> "  "

    fields =
      for {key, value} <- Enum.sort(map),
          do: [inner, JSON.encode!(key), ": ", pretty(value, inner)]

    ["{\n", Enum.intersperse(fields, ",\n"), "\n", indent, "}"]
  end

  defp pretty([], _indent), do: "[]"

  defp pretty(list, indent) when is_list(list) do
    inner = indent <> "  "
    items = for value <- list, do: [inner, pretty(value, inner)]
    ["[\n", Enum.intersperse(items, ",\n"), "\n", indent, "]"]
  end

  defp pretty(value, _indent), do: JSON.encode!(value)
end
