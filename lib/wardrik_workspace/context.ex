defmodule WardrikWorkspace.Context do
  @moduledoc """
  What a workspace tells its agent as each turn begins, which
  `WardrikWorkspace` gives the turn through `c:Wardrik.Tool.context/1`:

    * the files `WardrikWorkspace.Spec.context/2` names, whole and in the
      order named, up to 16 KB in all, each with the version `write_file` and
      `edit_file` change it over;
    * the ones it names that are not written yet, so the agent can write them;
    * the names of the other files and folders at the top of its own tree, so
      a `MEMORY.md` that grows is found without filling the context;
    * the trees it shares, and which of them it can only read.

  An agent file names them:

      tools: [files]
      context: [SOUL.md, shared/team/CONVENTIONS.md]

  A file read in whole that a run which had read content from outside wrote
  taints the turn from its start, as reading it with `read_file` would. The
  names of the others are listed without reading them, and a name is listed
  only where it is plain, letters, digits, `.`, `-` and `_`, since a name is
  text a run chose too. The rest are counted, and `list_files` names them.
  """

  alias WardrikWorkspace.File
  alias WardrikWorkspace.Mount
  alias WardrikWorkspace.Spec
  alias WardrikWorkspace.Tools

  @max_bytes 16 * 1024
  @max_names 50
  @plain ~r{\A[A-Za-z0-9._-]+/?\z}

  @heading """
  # Your workspace

  Read as this turn began. read_file reads a file again, and write_file and \
  edit_file change one over the version it shows.\
  """

  @doc "What `spec` tells its agent before a turn, or `nil` where its workspace holds nothing yet."
  @spec text(Spec.t()) :: Wardrik.Tool.context()
  def text(%Spec{} = spec) do
    read = read(spec)

    sections =
      Enum.reject(
        [files(read), unwritten(read), unreadable(read), listing(spec), shared(spec)],
        &is_nil/1
      )

    case sections do
      [] -> nil
      sections -> told(Enum.join([@heading | sections], "\n\n"), read)
    end
  end

  defp told(text, read) do
    if Enum.any?(read, &(&1.state == :read and &1.tainted)), do: {:outside, text}, else: text
  end

  # Each file `context` names, read while the budget lasts.
  defp read(%Spec{} = spec) do
    {read, _left} = Enum.map_reduce(spec.context, @max_bytes, &read(spec, &1, &2))
    read
  end

  defp read(spec, path, left) do
    {:ok, mount, rest} = Spec.resolve(spec, path)

    case mount.backend.read(mount.tree, rest) do
      {:ok, %File{} = file, version} -> shown(path, file, version, left)
      :none -> {%{path: path, state: :unwritten}, left}
      {:error, reason} -> {%{path: path, state: :unreadable, reason: reason}, left}
    end
  end

  defp shown(path, file, version, left) do
    shown = cut(file.content, left)

    read = %{
      path: path,
      state: if(shown == "" and file.content != "", do: :past, else: :read),
      shown: shown,
      size: byte_size(file.content),
      version: Tools.version(version),
      tainted: file.tainted
    }

    # A file cut short spends the budget, the bytes a cut left between two
    # characters included.
    {read, if(byte_size(shown) < read.size, do: 0, else: left - read.size)}
  end

  defp cut(content, left) when byte_size(content) <= left, do: content
  defp cut(content, left), do: whole_characters(binary_part(content, 0, left))

  # A cut inside a character keeps the characters before it.
  defp whole_characters(text) do
    if String.valid?(text),
      do: text,
      else: whole_characters(binary_part(text, 0, byte_size(text) - 1))
  end

  defp files(read) do
    case for(%{state: state} = file when state in [:read, :past] <- read, do: file(file)) do
      [] -> nil
      files -> Enum.join(files, "\n\n")
    end
  end

  defp file(%{state: :past} = file),
    do:
      "#{file.path} (version #{file.version}, #{file.size} bytes) is past the #{@max_bytes} bytes read into each turn; read_file reads it."

  defp file(%{shown: shown, size: size} = file) when byte_size(shown) < size,
    do:
      ~s(<file path="#{file.path}" version="#{file.version}" shown="the first #{byte_size(shown)} of #{size} bytes; read_file reads the rest">\n#{shown}\n</file>)

  defp file(file),
    do: ~s(<file path="#{file.path}" version="#{file.version}">\n#{file.shown}\n</file>)

  defp unwritten(read) do
    case for(%{state: :unwritten, path: path} <- read, do: path) do
      [] -> nil
      paths -> "Not written yet: #{Enum.join(paths, ", ")}."
    end
  end

  defp unreadable(read) do
    case for(%{state: :unreadable, path: path} <- read, do: path) do
      [] -> nil
      paths -> "Could not be read just now: #{Enum.join(paths, ", ")}. read_file tries again."
    end
  end

  # The files and folders at the top of the agent's own tree, but for those
  # read in whole above.
  defp listing(%Spec{tree: %Mount{} = mount, context: context}) do
    case mount.backend.paths(mount.tree, "") do
      {:ok, paths} -> paths |> Enum.map(&top/1) |> Enum.uniq() |> Kernel.--(context) |> names()
      {:error, _reason} -> nil
    end
  end

  defp top(path) do
    case String.split(path, "/", parts: 2) do
      [file] -> file
      [folder, _rest] -> folder <> "/"
    end
  end

  defp names([]), do: nil

  defp names(names) do
    {plain, other} = names |> Enum.sort() |> Enum.split_with(&Regex.match?(@plain, &1))
    {shown, over} = Enum.split(plain, @max_names)

    Enum.join(
      Enum.reject(
        [
          shown != [] &&
            "Also at the top of your workspace: #{Enum.join(shown, ", ")}. read_file reads one when what you are doing needs it.",
          more(length(over) + length(other))
        ],
        &(&1 in [false, nil])
      ),
      " "
    )
  end

  defp more(0), do: nil
  defp more(1), do: "One more is there, which list_files names."
  defp more(count), do: "#{count} more are there, which list_files names."

  defp shared(%Spec{shared: []}), do: nil

  defp shared(%Spec{shared: shared}),
    do: "Shared with you: #{Enum.map_join(shared, ", ", &mount/1)}."

  defp mount(%Mount{mode: :read} = mount), do: Mount.root(mount) <> " (read only)"

  defp mount(%Mount{} = mount), do: Mount.root(mount)
end
