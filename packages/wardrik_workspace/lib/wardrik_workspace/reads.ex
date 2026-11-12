defmodule WardrikWorkspace.Reads do
  @moduledoc false

  alias WardrikWorkspace.File
  alias WardrikWorkspace.Files
  alias WardrikWorkspace.Path
  alias WardrikWorkspace.Spec
  alias WardrikWorkspace.Tools

  @max_lines 2000
  @max_read_bytes 128 * 1024
  @max_listed 500
  @max_matches 200
  @max_context 5

  @doc "Reads a file's lines, numbered from 1, with its version."
  @spec read_file(Spec.t(), map()) :: {:ok, map()}
  def read_file(spec, args) do
    with {:ok, mount, path} <- resolved(spec, args[:path]),
         {:ok, file, version} <- found(spec, mount, path) do
      lines = String.split(file.content, "\n")
      offset = args[:offset] || 1
      {shown, next} = window(lines, offset, min(args[:limit] || @max_lines, @max_lines))

      File.labelled(
        %{
          ok: true,
          path: args[:path],
          version: version,
          lines: length(lines),
          content: shown,
          next_offset: next
        },
        [file]
      )
    end
  end

  @doc "Lists the files a glob matches, newest first, with each one's size, writer and time."
  @spec list_files(Spec.t(), map()) :: {:ok, map()}
  def list_files(spec, args) do
    glob = args[:pattern] || "**"

    files =
      spec
      |> all()
      |> Enum.filter(fn {path, _file} -> Path.match?(glob, path) end)
      |> Enum.sort_by(fn {_path, file} -> file.at end, {:desc, DateTime})

    shown = Enum.take(files, @max_listed)

    listed =
      for {path, file} <- shown,
          do: %{path: path, bytes: byte_size(file.content), at: file.at, by: file.by}

    File.labelled(
      %{ok: true, files: listed, more: max(length(files) - @max_listed, 0)},
      Enum.map(shown, fn {_path, file} -> file end)
    )
  end

  @doc "Finds the lines a regular expression matches, with the lines around them where asked."
  @spec search_files(Spec.t(), map()) :: {:ok, map()}
  def search_files(spec, args) do
    case Regex.compile(args[:pattern] || "", "u") do
      {:ok, regex} ->
        searched(spec, regex, args[:glob] || "**", min(args[:context] || 0, @max_context))

      {:error, {why, _at}} ->
        Tools.failed(:bad_pattern, "#{args[:pattern]} isn't a regular expression: #{why}")
    end
  end

  defp searched(spec, regex, glob, around) do
    matches =
      for {path, file} <- all(spec),
          Path.match?(glob, path),
          match <- matches(path, file.content, regex, around),
          do: {match, file}

    shown = Enum.take(matches, @max_matches)

    File.labelled(
      %{
        ok: true,
        matches: Enum.map(shown, fn {match, _file} -> match end),
        more: max(length(matches) - @max_matches, 0)
      },
      Enum.map(shown, fn {_match, file} -> file end)
    )
  end

  defp matches(path, content, regex, around) do
    lines = content |> String.split("\n") |> Enum.with_index(1)

    for {line, number} <- lines, Regex.match?(regex, line) do
      %{path: path, line: number, text: line, around: around(lines, number, around)}
    end
  end

  defp around(_lines, _number, 0), do: []

  defp around(lines, number, around) do
    for {line, at} <- lines, at != number, abs(at - number) <= around, do: "#{at}\t#{line}"
  end

  defp all(spec) do
    for mount <- Spec.mounts(spec),
        {path, file, _version} <- Files.list(spec.store, mount.tree),
        do: {Spec.shown(mount, path), file}
  end

  defp window(lines, offset, limit) do
    taken = lines |> Enum.drop(offset - 1) |> Enum.take(limit)
    numbered = taken |> Enum.with_index(offset) |> Enum.map(fn {line, n} -> "#{n}\t#{line}" end)
    {shown, count} = within(numbered, @max_read_bytes)
    last = offset + count - 1
    {Enum.join(shown, "\n"), if(last < length(lines), do: last + 1)}
  end

  defp within(lines, budget) do
    shown =
      lines
      |> Enum.scan({0, nil}, fn line, {used, _line} -> {used + byte_size(line) + 1, line} end)
      |> Enum.take_while(fn {used, _line} -> used <= budget end)
      |> Enum.map(fn {_used, line} -> line end)

    {shown, length(shown)}
  end

  @doc false
  @spec resolved(Spec.t(), term()) :: {:ok, WardrikWorkspace.Mount.t(), String.t()} | {:ok, map()}
  def resolved(spec, path) do
    case Spec.resolve(spec, path) do
      {:ok, mount, path} -> {:ok, mount, path}
      {:error, why} -> Tools.failed(:bad_path, why)
    end
  end

  defp found(spec, mount, path) do
    case Files.read(spec.store, tree: mount.tree, path: path) do
      {:ok, file, version} ->
        {:ok, file, version}

      :none ->
        Tools.failed(
          :not_found,
          "#{Spec.shown(mount, path)} isn't there; list_files shows what is"
        )
    end
  end
end
