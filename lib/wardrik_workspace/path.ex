defmodule WardrikWorkspace.Path do
  @moduledoc """
  A path in a workspace, as a file tool is given one, and the globs that match
  them.

  A path is relative to the workspace, `notes/today.md`, and is normalised
  before anything reads it: `.` segments and repeated slashes go, and one that
  is absolute, climbs out with `..`, holds a NUL or a backslash, or is longer
  than 1,024 bytes is refused. Directories are prefixes, so there is nothing
  to create.

  A glob matches whole paths: `*` any run of characters within a segment, `?`
  one, and `**` any run of segments, so `notes/*.md` is the Markdown files in
  `notes` and `**/*.md` every Markdown file.
  """

  @max_bytes 1024

  @doc "The path `path` names, normalised, or a message saying why it names none."
  @spec normalize(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(path) when is_binary(path) do
    segments = path |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))

    cond do
      not String.valid?(path) or String.contains?(path, [<<0>>, "\\"]) ->
        {:error, "#{inspect(path)} is not a path; a path is text, with / between its parts"}

      byte_size(path) > @max_bytes ->
        {:error, "a path is at most #{@max_bytes} bytes"}

      String.starts_with?(path, ["/", "~"]) ->
        {:error, "#{path} is absolute; name a path within the workspace, such as notes/today.md"}

      ".." in segments ->
        {:error, "#{path} climbs out of the workspace with .."}

      segments == [] ->
        {:error, "#{inspect(path)} names no file"}

      true ->
        {:ok, Enum.join(segments, "/")}
    end
  end

  def normalize(path), do: {:error, "#{inspect(path)} is not a path"}

  @doc "Whether `path` is one `glob` matches."
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(glob, path) when is_binary(glob) and is_binary(path),
    do: Regex.match?(compile(glob), path)

  @doc "The regular expression `glob` is."
  @spec compile(String.t()) :: Regex.t()
  def compile(glob) when is_binary(glob) do
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
