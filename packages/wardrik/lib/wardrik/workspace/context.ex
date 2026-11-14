defmodule Wardrik.Workspace.Context do
  @moduledoc """
  Middleware that reads workspace files into the agent's instructions each turn.

      middleware: [{Wardrik.Workspace.Context, store: store, tree: tree, files: ["MEMORY.md"]}]

    * Adds a `# Your workspace` section: each of `:files`, then the other top-level files and
      the shared trees.
    * A file over its share of `:max_bytes` is cut to its start and end. The agent is asked to
      shorten it.
    * The files' labels, such as `"outside"`, are added to the turn.

  ## Options

  `Wardrik.Workspace`'s options, plus:

    * `:files` - paths to read into each turn. `[]` unless set.
    * `:max_bytes` - how much of `:files` to read in total. `16_384` unless set.
  """

  @behaviour Wardrik.Middleware

  alias Wardrik.Context
  alias Wardrik.Workspace.Files
  alias Wardrik.Workspace.Spec

  @max_names 50
  @plain ~r{\A[A-Za-z0-9._-]+/?\z}
  @heading "# Your workspace\n\nRead as this turn began. read_file reads a file again, and write_file and edit_file change one over the version it shows."

  @impl Wardrik.Middleware
  def call(%Context{step: :turn, instructions: instructions} = context, next, opts) do
    spec = Spec.new(opts)
    files = Keyword.get(opts, :files, [])
    read = read(spec, files, Keyword.get(opts, :max_bytes, 16_384))
    context = labelled(context, read)

    case next.(%{context | instructions: joined(instructions, told(spec, files, read))}) do
      {:ok, context} -> {:ok, %{context | instructions: instructions}}
      {:park, reason, context} -> {:park, reason, %{context | instructions: instructions}}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(context, next, _opts), do: next.(context)

  defp labelled(context, read) do
    labels =
      read
      |> Enum.flat_map(&Map.get(&1, :labels, []))
      |> Enum.uniq()

    case labels do
      [] -> context
      labels -> %{context | messages: last_labelled(context.messages, labels)}
    end
  end

  defp last_labelled([], _labels), do: []

  defp last_labelled(messages, labels) do
    {last, earlier} = List.pop_at(messages, -1)
    held = Map.get(last.metadata, :labels, [])
    metadata = Map.put(last.metadata, :labels, Enum.sort(Enum.uniq(held ++ labels)))
    earlier ++ [%{last | metadata: metadata}]
  end

  defp joined(nil, text), do: text
  defp joined(instructions, text), do: instructions <> "\n\n" <> text

  @doc "Returns the workspace section, reading `files` within `budget` bytes."
  @spec text(Spec.t(), [String.t()], pos_integer()) :: String.t()
  def text(spec, files, budget), do: told(spec, files, read(spec, files, budget))

  defp told(spec, files, read) do
    [@heading, shown(read), crowded(read), unwritten(read), listing(spec, files), shared(spec)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp read(spec, files, budget) do
    found = Enum.map(files, &found(spec, &1))
    shares = shares(found, budget)
    Enum.map(found, &cut(&1, shares))
  end

  defp found(spec, path) do
    with {:ok, mount, rest} <- Spec.resolve(spec, path),
         {:ok, file, version} <- Files.read(spec.store, tree: mount.tree, path: rest) do
      %{
        path: path,
        state: :found,
        content: file.content,
        version: version,
        labels: Wardrik.Workspace.File.labels(file)
      }
    else
      _unwritten -> %{path: path, state: :unwritten}
    end
  end

  defp shares(found, budget) do
    sized =
      for %{state: :found, path: path, content: content} <- found, do: {path, byte_size(content)}

    sized
    |> Enum.sort_by(fn {_path, size} -> size end)
    |> Enum.with_index()
    |> Enum.map_reduce(budget, fn {{path, size}, index}, left ->
      take = min(size, div(left, length(sized) - index))
      {{path, take}, left - take}
    end)
    |> elem(0)
    |> Map.new()
  end

  defp cut(%{state: :found, content: content} = file, shares) do
    share = Map.fetch!(shares, file.path)

    if byte_size(content) <= share,
      do: file,
      else: Map.merge(%{file | state: :cut}, ends(content, share))
  end

  defp cut(file, _shares), do: file

  defp ends(content, share) do
    head = whole(binary_part(content, 0, div(share, 2)), :head)
    tail = whole(binary_part(content, byte_size(content), -(share - byte_size(head))), :tail)
    %{head: head, tail: tail, left_out: byte_size(content) - byte_size(head) - byte_size(tail)}
  end

  defp whole(text, side) do
    cond do
      String.valid?(text) -> text
      side == :head -> whole(binary_part(text, 0, byte_size(text) - 1), side)
      true -> whole(binary_part(text, 1, byte_size(text) - 1), side)
    end
  end

  defp shown(read) do
    case for(%{state: state} = file when state in [:found, :cut] <- read, do: file(file)) do
      [] -> nil
      files -> Enum.join(files, "\n\n")
    end
  end

  defp file(%{state: :found} = file),
    do: ~s(<file path="#{file.path}" version="#{file.version}">\n#{file.content}\n</file>)

  defp file(%{state: :cut} = file) do
    ~s(<file path="#{file.path}" version="#{file.version}" shown="its start and end">\n) <>
      file.head <>
      "\n[#{file.left_out} bytes are left out here; read_file reads them]\n" <>
      file.tail <> "\n</file>"
  end

  defp crowded(read) do
    case for %{state: :cut, path: path} <- read,
             not String.starts_with?(path, "shared/"),
             do: path do
      [] ->
        nil

      paths ->
        "#{Enum.join(paths, ", ")} is longer than what's read of it into each turn. Rewrite it shorter: fold what's older into a summary, and keep what's only a record in files of their own, by date."
    end
  end

  defp unwritten(read) do
    case for %{state: :unwritten, path: path} <- read, do: path do
      [] -> nil
      paths -> "Not written yet: #{Enum.join(paths, ", ")}."
    end
  end

  defp listing(spec, files) do
    names =
      spec.store
      |> Files.paths(spec.own.tree)
      |> Enum.map(&top/1)
      |> Enum.uniq()
      |> Kernel.--(files)
      |> Enum.sort()

    {plain, other} = Enum.split_with(names, &Regex.match?(@plain, &1))
    {shown, over} = Enum.split(plain, @max_names)
    listed(shown, length(over) + length(other))
  end

  defp listed([], 0), do: nil

  defp listed([], more),
    do: "#{more} more files are at the top of your workspace, which list_files names."

  defp listed(shown, more) do
    also =
      "Also at the top of your workspace: #{Enum.join(shown, ", ")}. read_file reads one when what you're doing needs it."

    if more > 0, do: also <> " #{more} more are there, which list_files names.", else: also
  end

  defp top(path) do
    case String.split(path, "/", parts: 2) do
      [file] -> file
      [folder, _rest] -> folder <> "/"
    end
  end

  defp shared(%Spec{shared: []}), do: nil

  defp shared(%Spec{shared: shared}) do
    trees =
      Enum.map_join(shared, ", ", fn mount ->
        "shared/#{mount.name}" <> if(mount.mode == :read, do: " (read only)", else: "")
      end)

    "Shared with you: #{trees}."
  end
end
