defmodule WardrikWorkspace.Context do
  @moduledoc """
  What a workspace tells its agent as each turn begins, which
  `WardrikWorkspace` gives the turn through `c:Wardrik.Tool.context/2`,
  from the store of the turn's host:

    * the files `WardrikWorkspace.Spec.context/2` names, in the order named,
      within the spec's budget, 16 KB unless set otherwise, each with the
      version `write_file` and `edit_file` change it over;
    * the ones it names that are not written yet, so the agent can write them;
    * the names of the other files and folders at the top of its own tree, so
      a `MEMORY.md` that grows is found without filling the context;
    * the trees it shares, and which of them it can only read.

  An agent file names them:

      tools: [files]
      context: [SOUL.md, shared/team/CONVENTIONS.md]

  ## The budget

  A file that fits its share of the budget is read whole, and what the
  smaller files leave is shared evenly among the larger, so one long file
  never keeps the others out. A file longer than its share is read from its
  start and from its end, between lines where it can be, and what is left out
  between them is said: a file kept by appending to it keeps its newest lines
  in view. A file of the agent's own tree that is cut is named with a request
  to rewrite it shorter, so memory the agent keeps stays within what it reads
  each turn.

  ## What a file holds

  A file read in part or whole labels the turn from its start with the
  labels of what the runs that wrote it had read, as reading it with
  `read_file` would. The names of the others are listed without reading them,
  and a name is listed only where it is plain, letters, digits, `.`, `-` and
  `_`, since a name is text a run chose too. The rest are counted, and
  `list_files` names them.
  """

  alias WardrikWorkspace.File
  alias WardrikWorkspace.Mount
  alias WardrikWorkspace.Spec
  alias WardrikWorkspace.Tools

  @max_names 50
  @plain ~r{\A[A-Za-z0-9._-]+/?\z}

  @heading """
  # Your workspace

  Read as this turn began. read_file reads a file again, and write_file and \
  edit_file change one over the version it shows.\
  """

  @doc """
  What `spec` tells its agent before a turn on `host`, or `nil` where its
  workspace holds nothing yet.
  """
  @spec text(Spec.t(), Wardrik.Host.t()) :: Wardrik.Tool.context()
  def text(%Spec{} = spec, host) do
    read = read(spec, host)

    sections =
      Enum.reject(
        [
          files(read),
          crowded(read),
          unwritten(read),
          unreadable(read),
          listing(spec, host),
          shared(spec)
        ],
        &is_nil/1
      )

    case sections do
      [] -> nil
      sections -> told(Enum.join([@heading | sections], "\n\n"), read)
    end
  end

  defp told(text, read) do
    shown = for %{state: state} = file <- read, state in [:whole, :cut], do: file

    case Enum.reduce(shown, [], &Wardrik.Label.union(&2, &1.labels)) do
      [] -> text
      labels -> {text, labels}
    end
  end

  # Each file `context` names, with as much of it as its share of the budget
  # holds.
  defp read(%Spec{} = spec, host) do
    found = Enum.map(spec.context, &found(spec, host, &1))
    shares = shares(found, spec.context_bytes)
    Enum.map(found, &shown(&1, shares))
  end

  defp found(spec, host, path) do
    {:ok, mount, rest} = Spec.resolve(spec, path)

    case mount.backend.read(host, mount.tree, rest) do
      {:ok, %File{} = file, version} -> %{path: path, state: :found, file: file, version: version}
      :none -> %{path: path, state: :unwritten}
      {:error, reason} -> %{path: path, state: :unreadable, reason: reason}
    end
  end

  # The smallest files first: each takes what it needs up to an even share of
  # what is left, so what a short file does not use goes to the longer ones.
  defp shares(found, budget) do
    sized =
      for %{state: :found, path: path, file: file} <- found,
          do: {path, byte_size(file.content)}

    {shares, _left, _count} =
      sized
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.reduce({%{}, budget, length(sized)}, fn {path, size}, {shares, left, count} ->
        take = min(size, div(left, count))
        {Map.put(shares, path, take), left - take, count - 1}
      end)

    shares
  end

  defp shown(%{state: :found, file: file} = found, shares) do
    size = byte_size(file.content)
    share = Map.fetch!(shares, found.path)

    base = %{
      path: found.path,
      size: size,
      version: Tools.version(found.version),
      labels: file.labels
    }

    if size <= share do
      Map.merge(base, %{state: :whole, content: file.content})
    else
      head = head(file.content, div(share, 2))
      tail = tail(file.content, share - byte_size(head))
      Map.merge(base, %{state: :cut, head: head, tail: tail})
    end
  end

  defp shown(other, _shares), do: other

  # The start of `content` in at most `bytes`, ending where a line ends within
  # them, and between characters where none does.
  defp head(content, bytes) do
    part = whole_characters(binary_part(content, 0, bytes), :trailing)

    case :binary.matches(part, "\n") do
      [] -> part
      lines -> binary_part(part, 0, elem(List.last(lines), 0) + 1)
    end
  end

  # The end of `content` in at most `bytes`, beginning where a line begins
  # within them.
  defp tail(content, bytes) do
    part = whole_characters(binary_part(content, byte_size(content), -bytes), :leading)

    case :binary.match(part, "\n") do
      :nomatch -> part
      {at, 1} -> binary_part(part, at + 1, byte_size(part) - at - 1)
    end
  end

  # A cut inside a character keeps the characters on the kept side of it.
  defp whole_characters(text, side) do
    cond do
      String.valid?(text) -> text
      side == :trailing -> whole_characters(binary_part(text, 0, byte_size(text) - 1), side)
      true -> whole_characters(binary_part(text, 1, byte_size(text) - 1), side)
    end
  end

  defp files(read) do
    case for(%{state: state} = file when state in [:whole, :cut] <- read, do: file(file)) do
      [] -> nil
      files -> Enum.join(files, "\n\n")
    end
  end

  defp file(%{state: :whole} = file),
    do: ~s(<file path="#{file.path}" version="#{file.version}">\n) <> closed(file.content)

  defp file(%{state: :cut, head: head, tail: tail} = file) do
    left_out = file.size - byte_size(head) - byte_size(tail)

    IO.iodata_to_binary([
      ~s(<file path="#{file.path}" version="#{file.version}" ),
      ~s(shown="its first #{byte_size(head)} and last #{byte_size(tail)} of #{file.size} bytes">\n),
      head,
      "\n[#{left_out} bytes are left out here; read_file reads them]\n\n",
      closed(tail)
    ])
  end

  # What a file holds, and the tag that closes it on a line of its own.
  defp closed(text) do
    if String.ends_with?(text, "\n"), do: text <> "</file>", else: text <> "\n</file>"
  end

  # The files of the agent's own tree read in part, which it can make fit.
  defp crowded(read) do
    case for(%{state: :cut, path: path} <- read, not shared?(path), do: path) do
      [] ->
        nil

      [path] ->
        "#{path} is longer than what is read of it into each turn. #{shorter("it")}"

      paths ->
        "#{Enum.join(paths, ", ")} are longer than what is read of them into each turn. #{shorter("them")}"
    end
  end

  defp shared?(path), do: String.starts_with?(path, "shared/")

  defp shorter(them),
    do:
      "Rewrite #{them} shorter: fold what is older into a summary, and keep what is only a record in files of their own, by date, which are named here rather than read."

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
  # read above.
  defp listing(%Spec{tree: %Mount{} = mount, context: context}, host) do
    case mount.backend.paths(host, mount.tree, "") do
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
