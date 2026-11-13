defmodule WardrikDaemon.EnvFile do
  @moduledoc false

  @doc "Returns `env` with each variable the file at `path` sets that `env` doesn't. A missing file sets none."
  @spec load(Path.t(), %{String.t() => String.t()}) :: %{String.t() => String.t()}
  def load(path, env) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> variables()
        |> Map.merge(env)

      {:error, _reason} ->
        env
    end
  end

  @doc "Returns the line numbers in the file at `path` that set no variable and aren't blank or a comment."
  @spec unread(Path.t()) :: [pos_integer()]
  def unread(path) do
    path
    |> File.read!()
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _number} -> unread?(line) end)
    |> Enum.map(fn {_line, number} -> number end)
  end

  defp unread?(line) do
    trimmed = String.trim(line)
    trimmed != "" and not String.starts_with?(trimmed, "#") and variable(line) == []
  end

  defp variables(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.flat_map(&variable/1)
    |> Map.new()
  end

  defp variable(line) do
    line =
      line
      |> String.trim()
      |> String.replace_prefix("export ", "")

    case String.split(line, "=", parts: 2) do
      ["#" <> _comment | _rest] ->
        []

      [name, value] ->
        if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
          do: [{name, unquoted(value)}],
          else: []

      _blank ->
        []
    end
  end

  defp unquoted("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp unquoted("'" <> rest), do: String.trim_trailing(rest, "'")
  defp unquoted(value), do: value
end
