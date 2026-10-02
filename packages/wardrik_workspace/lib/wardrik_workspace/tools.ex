defmodule WardrikWorkspace.Tools do
  @moduledoc """
  The six file tools `WardrikWorkspace` offers an agent, each handed its
  `Wardrik.Call`, and what each answers.

  | Tool | Takes | Answers |
  | --- | --- | --- |
  | `read_file` | `path`, `offset`, `limit` | numbered lines, at most 2,000 or 128 KB, and the file's version |
  | `write_file` | `path`, `content`, `version`, `append` | the new version. Over a file that exists it takes the version `read_file` gave; an append takes none |
  | `edit_file` | `path`, `old`, `new`, `all` | how many places changed; `old` must appear once unless `all` |
  | `list_files` | `pattern`, a glob | paths, newest first, at most 500 |
  | `search_files` | `pattern`, a regular expression; `glob`; `context` | matching lines, at most 200 |
  | `delete_file` | `path` | whether it was there |

  A write records who wrote it, in which run, with which call, and whether
  that run had read content from outside. An append or an edit keeps the
  mark the file had, since what was there before is there still, and a
  write that replaces the whole file takes its writer's. Reading a file a
  tainted run wrote,
  or listing or finding one, taints the reader's call, and with it the
  reader's run (see `Wardrik.Call.taint/1`). A call run again after a lost node
  finds its own write on the file and answers as it did, without writing
  twice.
  """

  alias Wardrik.Tool.Result
  alias WardrikWorkspace.File
  alias WardrikWorkspace.Mount
  alias WardrikWorkspace.Path
  alias WardrikWorkspace.Spec

  @max_lines 2000
  @max_read_bytes 128 * 1024
  @max_file_bytes 4 * 1024 * 1024
  @max_listed 500
  @max_matches 200
  @max_context 5
  @tries 8

  @names ~w(read_file write_file edit_file list_files search_files delete_file)

  @doc "The names of the file tools."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The file tools over `spec`."
  @spec build(Spec.t()) :: [ReqLLM.Tool.t()]
  def build(%Spec{} = spec) do
    for name <- @names do
      {description, schema} = definition(name)

      Wardrik.Tool.new!(
        name: name,
        description: description,
        parameter_schema: schema,
        run: {__MODULE__, :handle, [String.to_existing_atom(name), spec]}
      )
    end
  end

  defp definition("read_file") do
    {"""
     Read a file in your workspace. Answers its lines numbered from 1, and its version, which write_file needs to replace it. Reads at most #{@max_lines} lines at a time: pass offset and limit for more. Files other agents share with you are under shared/<name>/.
     """,
     [
       path: [
         type: :string,
         required: true,
         doc: "The file, relative to the workspace, as notes/today.md"
       ],
       offset: [type: :pos_integer, doc: "The first line to read, 1 unless given"],
       limit: [type: :pos_integer, doc: "How many lines to read, at most #{@max_lines}"]
     ]}
  end

  defp definition("write_file") do
    {"""
     Write a file in your workspace, creating it or replacing it whole. To replace a file that exists, pass the version read_file gave you; if it has changed since, read it again. With append, adds content to the end instead, creating the file if it is missing, and needs no version: use it for logs and lists. Directories need no creating.
     """,
     [
       path: [
         type: :string,
         required: true,
         doc: "The file, relative to the workspace, as notes/today.md"
       ],
       content: [
         type: :string,
         required: true,
         doc: "What the file holds, or what to add to its end"
       ],
       version: [type: :string, doc: "The version read_file gave, to replace a file that exists"],
       append: [type: :boolean, doc: "Add content to the end rather than replacing the file"]
     ]}
  end

  defp definition("edit_file") do
    {"""
     Replace text in a file in your workspace: old must appear exactly once, unless all is true, which replaces every occurrence. Prefer it to rewriting a whole file.
     """,
     [
       path: [type: :string, required: true, doc: "The file, relative to the workspace"],
       old: [
         type: :string,
         required: true,
         doc: "The text to replace, exactly as the file has it"
       ],
       new: [type: :string, required: true, doc: "What replaces it"],
       all: [type: :boolean, doc: "Replace every occurrence rather than exactly one"]
     ]}
  end

  defp definition("list_files") do
    {"""
     List the files in your workspace whose paths match a glob, newest first: ** for every file, notes/*.md for the Markdown files in notes, shared/team/** for a tree shared with you. Shows each file's size, when it was written and who wrote it.
     """,
     [
       pattern: [
         type: :string,
         doc: "A glob: * within a directory, ** across them. ** unless given"
       ]
     ]}
  end

  defp definition("search_files") do
    {"""
     Search the files in your workspace for lines matching a regular expression, only those whose paths match glob where it is given. Answers each matching line with its path and line number, and the lines around it where context is given.
     """,
     [
       pattern: [type: :string, required: true, doc: "A regular expression"],
       glob: [type: :string, doc: "Search only the files whose paths match this glob"],
       context: [
         type: :non_neg_integer,
         doc: "How many lines before and after each match to show, at most #{@max_context}"
       ]
     ]}
  end

  defp definition("delete_file") do
    {"Delete a file in your workspace. Says whether it was there.\n",
     [path: [type: :string, required: true, doc: "The file, relative to the workspace"]]}
  end

  @doc false
  @spec handle(atom(), Spec.t(), map(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.answer()
  def handle(tool, %Spec{} = spec, args, %Wardrik.Tool.Context{} = context) do
    case run(tool, spec, args, context) do
      {:ok, answer, outside: outside?} ->
        {:ok, result} = Result.ok(answer)
        {:ok, result, outside: outside?}

      {:ok, answer} ->
        Result.ok(answer)

      {:error, code, message} ->
        Result.error(code, message)
    end
  end

  # -- read ------------------------------------------------------------------

  defp run(:read_file, spec, args, _context) do
    with {:ok, mount, path} <- resolve(spec, args.path),
         {:ok, file, version} <- existing(mount, path) do
      offset = Map.get(args, :offset, 1)
      limit = min(Map.get(args, :limit, @max_lines), @max_lines)
      lines = lines(file.content)
      {shown, cut?} = numbered(lines, offset, limit)

      {:ok,
       %{
         "path" => shown_path(mount, path),
         "version" => version(version),
         "lines" => length(lines),
         "content" => shown,
         "truncated" => cut?
       }, outside: outside?([file])}
    end
  end

  # -- write -----------------------------------------------------------------

  defp run(:write_file, spec, args, context) do
    with {:ok, mount, path} <- writable(spec, args.path),
         :ok <- fits(args.content) do
      if Map.get(args, :append, false),
        do: append(mount, path, args.content, context, @tries),
        else: replace(mount, path, args, context)
    end
  end

  defp run(:edit_file, spec, args, context) do
    with {:ok, mount, path} <- writable(spec, args.path),
         :ok <- present(args.old) do
      edit(mount, path, args, context, @tries)
    end
  end

  defp run(:delete_file, spec, args, _context) do
    with {:ok, mount, path} <- writable(spec, args.path), do: delete(mount, path, @tries)
  end

  # -- look ------------------------------------------------------------------

  defp run(:list_files, spec, args, _context) do
    glob = Map.get(args, :pattern) || "**"

    with {:ok, files} <- view(spec) do
      listed =
        files
        |> Enum.filter(fn {path, _file} -> Path.match?(glob, path) end)
        |> Enum.sort_by(fn {path, file} -> {file.at, path} end, &newest/2)

      {:ok,
       %{
         "files" => listed |> Enum.take(@max_listed) |> Enum.map(&listing/1),
         "truncated" => length(listed) > @max_listed
       }, outside: outside?(Enum.map(listed, &elem(&1, 1)))}
    end
  end

  defp run(:search_files, spec, args, _context) do
    glob = Map.get(args, :glob) || "**"
    context = min(Map.get(args, :context, 0), @max_context)

    with {:ok, regex} <- regex(args.pattern),
         {:ok, files} <- view(spec) do
      found =
        files
        |> Enum.filter(fn {path, _file} -> Path.match?(glob, path) end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(fn {path, file} -> matches(path, file, regex, context) end)

      {:ok,
       %{
         "matches" => found |> Enum.take(@max_matches) |> Enum.map(&elem(&1, 0)),
         "truncated" => length(found) > @max_matches
       }, outside: outside?(found |> Enum.take(@max_matches) |> Enum.map(&elem(&1, 1)))}
    end
  end

  # -- changing a file ---------------------------------------------------------

  # Over a file that exists, only with the version read; where none is, only
  # while none is. A file whose last write was this call's is this call run
  # again, answered as written.
  defp replace(mount, path, args, context) do
    key = context.idempotency_key

    case read(mount, path) do
      {:ok, %File{call: ^key}, version} ->
        {:ok, written(mount, path, version)}

      {:ok, _file, version} ->
        over(mount, path, args, context, version)

      :none ->
        mount |> put(path, args.content, context, nil) |> lost(fn -> created(mount, path) end)

      {:error, reason} ->
        unavailable(reason)
    end
  end

  defp over(mount, path, args, context, version) do
    cond do
      args[:version] == nil ->
        {:error, :exists,
         "#{shown_path(mount, path)} exists: read it, and pass the version read_file gives to replace it"}

      args[:version] != version(version) ->
        changed(mount, path)

      true ->
        mount |> put(path, args.content, context, version) |> lost(fn -> changed(mount, path) end)
    end
  end

  # Appends commute, so one that loses to another writer reads again and
  # tries again.
  defp append(mount, path, content, context, tries) do
    key = context.idempotency_key
    retry = fn -> append(mount, path, content, context, tries - 1) end

    case read(mount, path) do
      {:ok, %File{call: ^key}, version} ->
        {:ok, written(mount, path, version)}

      {:ok, %File{content: old} = file, version} ->
        with :ok <- fits(old <> content),
             do: again(put(mount, path, old <> content, {context, file}, version), retry, tries)

      :none ->
        again(put(mount, path, content, context, nil), retry, tries)

      {:error, reason} ->
        unavailable(reason)
    end
  end

  # An edit that loses to another writer reads again, and applies again where
  # old still matches.
  defp edit(mount, path, args, context, tries) do
    with {:ok, file, version} <- existing(mount, path) do
      if file.call == context.idempotency_key,
        do: {:ok, written(mount, path, version)},
        else: edited(mount, path, args, {context, file, version}, tries)
    end
  end

  defp edited(mount, path, args, {context, file, version}, tries) do
    all? = Map.get(args, :all, false)

    with {:ok, count} <- occurrences(mount, path, file.content, args.old, all?),
         content = String.replace(file.content, args.old, args.new, global: all?),
         :ok <- fits(content) do
      mount
      |> put(path, content, {context, file}, version)
      |> replaced(if(all?, do: count, else: 1))
      |> again(fn -> edit(mount, path, args, context, tries - 1) end, tries)
    end
  end

  defp occurrences(mount, path, content, old, all?) do
    case length(:binary.matches(content, old)) do
      0 ->
        {:error, :not_found,
         "#{shown_path(mount, path)} does not contain old; read it to see what it holds"}

      count when count > 1 and not all? ->
        {:error, :ambiguous,
         "old appears #{count} times in #{shown_path(mount, path)}; give more of the text around it, or all: true"}

      count ->
        {:ok, count}
    end
  end

  defp replaced({:ok, answer}, count), do: {:ok, Map.put(answer, "replaced", count)}
  defp replaced(other, _count), do: other

  defp delete(mount, path, tries) do
    case read(mount, path) do
      :none ->
        {:ok, %{"path" => shown_path(mount, path), "deleted" => false}}

      {:ok, _file, version} ->
        mount.backend.delete(mount.tree, path, version)
        |> removed(mount, path)
        |> again(fn -> delete(mount, path, tries - 1) end, tries)

      {:error, reason} ->
        unavailable(reason)
    end
  end

  defp removed(:ok, mount, path),
    do: {:ok, %{"path" => shown_path(mount, path), "deleted" => true}}

  defp removed({:error, :conflict}, _mount, _path), do: :conflict
  defp removed({:error, reason}, _mount, _path), do: unavailable(reason)

  # Writes `content` as this call's, over `version`, answering `:conflict`
  # where the file has changed since. Content kept from the file written
  # before, by an append or an edit, keeps its mark: a file is tainted while
  # anything a tainted run wrote may still be in it.
  defp put(mount, path, content, {context, %File{tainted: kept}}, version),
    do: write(mount, path, content, context, version, kept)

  defp put(mount, path, content, context, version),
    do: write(mount, path, content, context, version, false)

  defp write(mount, path, content, %Wardrik.Tool.Context{scope: scope} = context, version, kept) do
    file = %File{
      content: content,
      by: scope.source.agent_id,
      run: scope.source.trace.trace_id,
      call: context.idempotency_key,
      tainted: scope.tainted or kept,
      at: DateTime.utc_now()
    }

    case mount.backend.write(mount.tree, path, file, version) do
      {:ok, version} -> {:ok, written(mount, path, version)}
      {:error, :conflict} -> :conflict
      {:error, reason} -> unavailable(reason)
    end
  end

  # A conflict, answered with what `lost` says.
  defp lost(:conflict, lost), do: lost.()
  defp lost(answer, _lost), do: answer

  # A conflict, tried again while tries are left, after a wait that grows
  # with each, so writers that keep meeting spread out.
  defp again(:conflict, _next, tries) when tries <= 1,
    do: {:error, :conflict, "Others kept changing the file; try again"}

  defp again(:conflict, next, tries) do
    Process.sleep(:rand.uniform(5 * Integer.pow(2, min(@tries - tries, 5))))
    next.()
  end

  defp again(answer, _next, _tries), do: answer

  # -- helpers -----------------------------------------------------------------

  defp resolve(spec, path) do
    case Spec.resolve(spec, path) do
      {:ok, mount, path} -> {:ok, mount, path}
      {:error, message} -> {:error, :invalid_path, message}
    end
  end

  defp writable(spec, path) do
    with {:ok, %Mount{mode: mode} = mount, path} <- resolve(spec, path) do
      if mode == :read,
        do:
          {:error, :read_only, "shared/#{mount.name} is shared with you to read, not to change"},
        else: {:ok, mount, path}
    end
  end

  defp read(%Mount{backend: backend, tree: tree}, path), do: backend.read(tree, path)

  defp existing(mount, path) do
    case read(mount, path) do
      {:ok, file, version} -> {:ok, file, version}
      :none -> {:error, :not_found, "#{shown_path(mount, path)} does not exist"}
      {:error, reason} -> unavailable(reason)
    end
  end

  # Every file of every mount, under the path the agent sees it at.
  defp view(spec) do
    spec
    |> Spec.mounts()
    |> Enum.reduce_while({:ok, []}, fn mount, {:ok, seen} ->
      case mount.backend.list(mount.tree, "") do
        {:ok, listed} -> {:cont, {:ok, [seen(mount, listed) | seen]}}
        {:error, reason} -> {:halt, unavailable(reason)}
      end
    end)
    |> case do
      {:ok, seen} -> {:ok, seen |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  defp seen(mount, listed),
    do: for({path, file, _version} <- listed, do: {Mount.root(mount) <> path, file})

  defp fits(content) do
    if byte_size(content) <= @max_file_bytes,
      do: :ok,
      else: {:error, :too_large, "A file is at most #{div(@max_file_bytes, 1024 * 1024)} MiB"}
  end

  defp present(""), do: {:error, :invalid, "old is the text to replace, and cannot be empty"}
  defp present(_old), do: :ok

  defp regex(pattern) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} ->
        {:ok, regex}

      {:error, {reason, at}} ->
        {:error, :invalid, "pattern is not a regular expression: #{reason} at #{at}"}
    end
  end

  defp matches(path, file, regex, context) do
    lines = file.content |> lines() |> Enum.with_index(1)
    numbered = Map.new(lines, fn {text, n} -> {n, text} end)

    for {text, n} <- lines, Regex.match?(regex, text) do
      match = %{"path" => path, "line" => n, "text" => text}

      match =
        if context > 0,
          do:
            Map.merge(match, %{
              "before" => for(m <- max(n - context, 1)..(n - 1)//1, do: numbered[m]),
              "after" =>
                for(m <- (n + 1)..min(n + context, map_size(numbered))//1, do: numbered[m])
            }),
          else: match

      {match, file}
    end
  end

  # A file's lines, where a final newline ends the last one rather than
  # beginning another.
  defp lines(content) do
    case String.split(content, "\n") do
      [""] -> []
      lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    end
  end

  defp numbered(lines, offset, limit) do
    lines
    |> Enum.with_index(1)
    |> Enum.slice((offset - 1)..(offset + limit - 2)//1)
    |> Enum.reduce_while({[], 0}, fn {line, n}, {acc, bytes} ->
      shown = [String.pad_leading(Integer.to_string(n), 6), "\t", line]
      bytes = bytes + IO.iodata_length(shown) + 1
      if bytes > @max_read_bytes, do: {:halt, {acc, :cut}}, else: {:cont, {[shown | acc], bytes}}
    end)
    |> then(fn {acc, bytes} ->
      {acc |> Enum.reverse() |> Enum.intersperse("\n") |> IO.iodata_to_binary(),
       bytes == :cut or offset + limit - 1 < length(lines)}
    end)
  end

  defp listing({path, %File{} = file}) do
    %{
      "path" => path,
      "size" => byte_size(file.content),
      "at" => file.at && DateTime.to_iso8601(file.at),
      "by" => file.by
    }
  end

  defp newest({at_a, path_a}, {at_b, path_b}) do
    case {at_a, at_b} do
      {nil, nil} ->
        path_a <= path_b

      {nil, _b} ->
        false

      {_a, nil} ->
        true

      {a, b} ->
        DateTime.compare(a, b) == :gt or (DateTime.compare(a, b) == :eq and path_a <= path_b)
    end
  end

  # What a tainted run wrote is content from outside to whoever reads it.
  defp outside?(files), do: Enum.any?(files, & &1.tainted)

  defp written(mount, path, version),
    do: %{"path" => shown_path(mount, path), "version" => version(version)}

  defp created(mount, path) do
    {:error, :conflict,
     "#{shown_path(mount, path)} was written by someone else just now: read it before replacing it"}
  end

  defp changed(mount, path) do
    {:error, :conflict,
     "#{shown_path(mount, path)} has changed since you read it: read it again, and replace what it holds now"}
  end

  defp unavailable(reason),
    do: {:error, :unavailable, "The workspace could not be reached: #{inspect(reason)}"}

  defp shown_path(mount, path), do: Mount.root(mount) <> path

  @doc "The version a file tool shows for a backend's `version`: short, and the same for the same version."
  @spec version(term()) :: String.t()
  def version(version) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(version))
    |> binary_part(0, 6)
    |> Base.encode16(case: :lower)
  end
end
