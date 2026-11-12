defmodule WardrikWorkspace.Tools do
  @moduledoc """
  The six file tools.

  | Tool | Arguments | Answers |
  | --- | --- | --- |
  | `read_file` | `path`, `offset`, `limit` | Numbered lines, at most 2,000 or 128 KB, and the version |
  | `write_file` | `path`, `content`, `version`, `append` | The new version |
  | `edit_file` | `path`, `old`, `new`, `all` | How many places changed |
  | `list_files` | `pattern` (a glob) | Paths, newest first, at most 500 |
  | `search_files` | `pattern` (a regex), `glob`, `context` | Matching lines, at most 200 |
  | `delete_file` | `path` | Whether the file was there |

    * `write_file` needs the version read to replace a file, unless it appends.
    * `edit_file` needs `old` to appear once, unless `all` is true.
    * Files are at most 4 MiB.
    * A failed tool answers `%{ok: false, error: %{code: ..., message: ...}}`.
    * Each call's resource is its path or glob, for policies like `write_file(notes/*)`.
  """

  alias WardrikCore.Tool
  alias WardrikWorkspace.Reads
  alias WardrikWorkspace.Spec
  alias WardrikWorkspace.Writes

  @doc "Returns the file tools over `spec`."
  @spec build(Spec.t()) :: [Tool.t()]
  def build(%Spec{} = spec) do
    reading = [read_only: true, idempotent: true]

    [
      tool(
        "read_file",
        read_file(),
        fn args, _context -> Reads.read_file(spec, args) end,
        reading
      ),
      tool("write_file", write_file(), &Writes.write_file(spec, &1, &2), []),
      tool("edit_file", edit_file(), &Writes.edit_file(spec, &1, &2), []),
      tool(
        "list_files",
        list_files(),
        fn args, _context -> Reads.list_files(spec, args) end,
        reading
      ),
      tool(
        "search_files",
        search_files(),
        fn args, _context -> Reads.search_files(spec, args) end,
        reading
      ),
      tool("delete_file", delete_file(), fn args, _context -> Writes.delete_file(spec, args) end,
        idempotent: true
      )
    ]
  end

  defp tool(name, {description, schema}, run, annotations) do
    Tool.new!(
      name: name,
      description: description,
      schema: schema,
      run: run,
      annotations: Keyword.put(annotations, :resources, &resources(name, &1))
    )
  end

  defp resources(name, arguments) when name in ["list_files", "search_files"],
    do: [Map.get(arguments, if(name == "list_files", do: "pattern", else: "glob")) || "**"]

  defp resources(_name, %{"path" => path}) when is_binary(path), do: [path]
  defp resources(_name, _arguments), do: []

  @path [
    type: :string,
    required: true,
    doc: "The file, relative to the workspace, as notes/today.md"
  ]

  defp read_file do
    {"Read a file in your workspace. Answers its lines numbered from 1, and its version, which write_file needs to replace it. Reads at most 2000 lines at a time: pass offset and limit for more. Files shared with you are under shared/<name>/.",
     [
       path: @path,
       offset: [type: :pos_integer, doc: "The first line to read, 1 unless given"],
       limit: [type: :pos_integer, doc: "How many lines to read, at most 2000"]
     ]}
  end

  defp write_file do
    {"Write a file in your workspace, creating it or replacing it whole. To replace a file that's there, pass the version read_file gave you; if it changed since, read it again. With append, add content to its end instead, creating it if it's missing, with no version: use it for logs and lists. Folders need no creating.",
     [
       path: @path,
       content: [
         type: :string,
         required: true,
         doc: "What the file holds, or what to add to its end"
       ],
       version: [type: :string, doc: "The version read_file gave, to replace a file that's there"],
       append: [type: :boolean, doc: "Add content to the end, in place of replacing the file"]
     ]}
  end

  defp edit_file do
    {"Replace text in a file in your workspace: old must appear exactly once, unless all is true, which replaces each place it appears. Prefer it to writing a whole file again.",
     [
       path: @path,
       old: [
         type: :string,
         required: true,
         doc: "The text to replace, exactly as the file has it"
       ],
       new: [type: :string, required: true, doc: "What replaces it"],
       all: [type: :boolean, doc: "Replace each place it appears, not exactly one"]
     ]}
  end

  defp list_files do
    {"List the files in your workspace whose paths match a glob, newest first: ** for every file, notes/*.md for the Markdown files in notes, shared/team/** for a tree shared with you. Shows each file's size, when it was written and who wrote it.",
     [pattern: [type: :string, doc: "A glob: * within a folder, ** across them. ** unless given"]]}
  end

  defp search_files do
    {"Find the lines in your workspace's files that a regular expression matches, in the files a glob matches where one is given. Answers each with its path and line number, and the lines around it where context is given.",
     [
       pattern: [type: :string, required: true, doc: "A regular expression"],
       glob: [type: :string, doc: "Search only the files whose paths match this glob"],
       context: [
         type: :non_neg_integer,
         doc: "How many lines before and after each match to show, at most 5"
       ]
     ]}
  end

  defp delete_file,
    do: {"Delete a file in your workspace. Says whether it was there.", [path: @path]}

  @doc "Returns a tool's failure answer, with `code` and `message`."
  @spec failed(atom(), String.t()) :: {:ok, map()}
  def failed(code, message), do: {:ok, %{ok: false, error: %{code: code, message: message}}}
end
