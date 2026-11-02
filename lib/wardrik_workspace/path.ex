defmodule WardrikWorkspace.Path do
  @moduledoc """
  Paths and globs within a workspace.

      WardrikWorkspace.Path.normalize("notes//./today.md")
      #=> {:ok, "notes/today.md"}

    * A path is refused if it starts with `/` or `~`, holds `..`, a NUL or a backslash, or is
      over 1,024 bytes.
    * Folders are path prefixes. There's nothing to create.
    * In a glob, `*` matches within one folder, `?` one character, and `**` across folders.
  """

  @max_bytes 1024

  @doc "Normalises `path`. Returns `{:error, reason}` if it isn't a valid path."
  @spec normalize(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(path) when is_binary(path) do
    segments = path |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))

    cond do
      not String.valid?(path) or String.contains?(path, [<<0>>, "\\"]) ->
        {:error, "#{inspect(path)} isn't a path; a path is text, with / between its parts"}

      byte_size(path) > @max_bytes ->
        {:error, "a path is at most #{@max_bytes} bytes"}

      String.starts_with?(path, ["/", "~"]) ->
        {:error, "#{path} is absolute; name a path within the workspace, as notes/today.md"}

      ".." in segments ->
        {:error, "#{path} climbs out of the workspace with .."}

      segments == [] ->
        {:error, "#{inspect(path)} names no file"}

      true ->
        {:ok, Enum.join(segments, "/")}
    end
  end

  def normalize(path), do: {:error, "#{inspect(path)} isn't a path"}

  @doc "Returns whether `glob` matches `path`."
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(glob, path), do: Regex.match?(compile(glob), path)

  @doc "Compiles `glob` to a regular expression."
  @spec compile(String.t()) :: Regex.t()
  def compile(glob) do
    glob
    |> String.trim_leading("./")
    |> translate([])
    |> then(&Regex.compile!("\\A" <> &1 <> "\\z", "u"))
  end

  defp translate("**/" <> rest, acc), do: translate(rest, ["(?:.*/)?" | acc])
  defp translate("**" <> rest, acc), do: translate(rest, [".*" | acc])
  defp translate("*" <> rest, acc), do: translate(rest, ["[^/]*" | acc])
  defp translate("?" <> rest, acc), do: translate(rest, ["[^/]" | acc])

  defp translate(<<char::utf8, rest::binary>>, acc),
    do: translate(rest, [Regex.escape(<<char::utf8>>) | acc])

  defp translate("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
