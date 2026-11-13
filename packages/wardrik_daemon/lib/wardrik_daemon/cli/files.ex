defmodule WardrikDaemon.CLI.Files do
  @moduledoc false

  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Table

  @group "Files"

  @doc "Returns the commands on agents' files."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "agent files ls",
        group: @group,
        arguments: "AGENT [GLOB]",
        count: {1, :any},
        summary: "an agent's files, newest first",
        details: ["GLOB, as skills/**, lists only the paths it matches."],
        run: &listed/3
      },
      %Command{
        name: "agent files cat",
        group: @group,
        arguments: "AGENT PATH",
        count: 2,
        summary: "print one of an agent's files",
        run: &read/3
      },
      %Command{
        name: "agent files search",
        group: @group,
        arguments: "AGENT WORDS...",
        switches: [glob: :string, limit: :integer],
        count: {2, :any},
        summary: "find the agent's files that best answer some words, best first",
        details: [
          "Ranks its notes and digests by the words they share with WORDS, as search_memory does.",
          "--glob GLOB searches only the paths it matches. --limit N shows up to N, 5 unless set."
        ],
        run: &searched/3
      },
      %Command{
        name: "agent files put",
        group: @group,
        arguments: "AGENT PATH [FILE]",
        count: {2, :any},
        summary: "write one of an agent's files",
        details: ["Reads FILE, or stdin without one or with -. Replaces any file at PATH."],
        run: &put/3
      },
      %Command{
        name: "agent files rm",
        group: @group,
        arguments: "AGENT PATH",
        count: 2,
        summary: "delete one of an agent's files",
        run: &removed/3
      },
      %Command{
        name: "agent files sync",
        group: @group,
        arguments: "AGENT DIR",
        switches: [to: :string, delete: :boolean],
        count: 2,
        summary: "write a directory's files into an agent's workspace",
        details: [
          "Writes each file whose content differs, under --to PREFIX if given.",
          "--delete also deletes the agent's files under PREFIX that DIR doesn't have.",
          "Files and directories whose names start with . are left out, and so are files that",
          "aren't text."
        ],
        run: &synced/3
      }
    ]
  end

  defp listed([agent], flags, cx), do: listed(agent, %{}, flags, cx)
  defp listed([agent, glob], flags, cx), do: listed(agent, %{"glob" => glob}, flags, cx)

  defp listed(_args, _flags, cx),
    do: {:error, "Usage: #{cx.program} agent files ls AGENT [GLOB]"}

  defp listed(agent, input, _flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, %{"files" => files} = answer} <-
           Context.call(cx, "agent.files", Map.put(input, "agent", id)) do
      Table.show(cx, answer,
        header: ["PATH", "BYTES", "BY", "WRITTEN"],
        rows: Enum.map(files, &[&1["path"], &1["bytes"], &1["by"], &1["at"]]),
        empty: "No files."
      )
    end
  end

  defp searched([agent | words], flags, cx) do
    fields = %{"query" => Enum.join(words, " "), "glob" => flags[:glob], "limit" => flags[:limit]}
    input = Map.reject(fields, fn {_key, value} -> is_nil(value) end)

    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, %{"hits" => hits} = answer} <-
           Context.call(cx, "agent.memory_search", Map.put(input, "agent", id)) do
      Table.show(cx, answer,
        header: ["PATH", "LINE", "WRITTEN", "PASSAGE"],
        rows: Enum.map(hits, &[&1["path"], &1["line"], &1["at"], first_line(&1["excerpt"])]),
        empty: "Nothing matches."
      )
    end
  end

  defp first_line(excerpt) do
    line = hd(String.split(excerpt, "\n", parts: 2))
    if String.length(line) > 60, do: String.slice(line, 0, 59) <> "…", else: line
  end

  defp read([agent, path], _flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, answer} <- Context.call(cx, "agent.file", %{"agent" => id, "path" => path}),
         do: Context.show(cx, answer, &IO.write(&1["content"]))
  end

  defp put([agent, path], _flags, cx), do: put(agent, path, "-", cx)
  defp put([agent, path, file], _flags, cx), do: put(agent, path, file, cx)

  defp put(_args, _flags, cx),
    do: {:error, "Usage: #{cx.program} agent files put AGENT PATH [FILE]"}

  defp put(agent, path, file, cx) do
    with {:ok, content} <- content(file),
         {:ok, id} <- Context.agent(cx, agent),
         {:ok, answer} <- written(cx, id, path, content),
         do: Context.done(cx, answer, "Wrote #{path}.")
  end

  defp content("-"), do: text(IO.read(:stdio, :eof), "stdin")
  defp content(file), do: text(File.read(file), file)

  defp text(:eof, _from), do: {:ok, ""}
  defp text(read, from) when is_binary(read), do: text({:ok, read}, from)

  defp text({:ok, content}, from) do
    if String.valid?(content), do: {:ok, content}, else: {:error, "#{from} isn't text."}
  end

  defp text({:error, reason}, from),
    do: {:error, "#{from} can't be read: #{:file.format_error(reason)}."}

  defp removed([agent, path], _flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, answer} <- deleted(cx, id, path),
         do: Context.done(cx, answer, "Deleted #{path}.")
  end

  defp deleted(cx, id, path),
    do: Context.call(cx, "agent.file_delete", %{"agent" => id, "path" => path})

  defp written(cx, id, path, content),
    do: Context.call(cx, "agent.file_put", %{"agent" => id, "path" => path, "content" => content})

  defp synced([agent, dir], flags, cx) do
    prefix = String.trim(Map.get(flags, :to, ""), "/")

    with :ok <- directory(dir),
         {:ok, id} <- Context.agent(cx, agent),
         {:ok, %{"files" => there}} <-
           Context.call(cx, "agent.files", %{"agent" => id, "glob" => joined(prefix, "**")}) do
      {local, skipped} = local(dir, prefix)
      there = Map.new(there, &{&1["path"], &1})

      {kept, changed} =
        local
        |> Map.keys()
        |> Enum.sort()
        |> Enum.split_with(&same?(cx, id, there[&1], local[&1]))

      with {:ok, written} <- each(changed, &written(cx, id, &1, local[&1])),
           {:ok, deleted} <- each(deleting(there, local, flags[:delete]), &deleted(cx, id, &1)) do
        answer = %{
          "written" => written,
          "kept" => kept,
          "deleted" => deleted,
          "skipped" => skipped
        }

        Context.show(cx, answer, &said(cx, &1))
      end
    end
  end

  defp directory(dir) do
    if File.dir?(dir), do: :ok, else: {:error, "#{dir} isn't a directory."}
  end

  # The directory's files by their paths in the workspace, and those that aren't text.
  defp local(dir, prefix) do
    {text, skipped} =
      dir
      |> walk("")
      |> Enum.sort()
      |> Enum.map(&{&1, File.read!(Path.join(dir, &1))})
      |> Enum.split_with(fn {_relative, content} -> String.valid?(content) end)

    {Map.new(text, fn {relative, content} -> {joined(prefix, relative), content} end),
     Enum.map(skipped, &elem(&1, 0))}
  end

  defp walk(dir, relative) do
    dir
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.flat_map(fn name ->
      inner = joined(relative, name)
      if File.dir?(Path.join(dir, inner)), do: walk(dir, inner), else: [inner]
    end)
  end

  defp joined("", name), do: name
  defp joined(folder, name), do: folder <> "/" <> name

  # Runs `run` on each path until one fails.
  defp each(paths, run) do
    ran =
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, done} ->
        case run.(path) do
          {:ok, _answer} -> {:cont, {:ok, [path | done]}}
          {:error, why} -> {:halt, {:error, "#{path}: #{why}"}}
        end
      end)

    with {:ok, done} <- ran, do: {:ok, Enum.reverse(done)}
  end

  # A file of another size differs. One of the same size is read to compare.
  defp same?(_cx, _id, nil, _content), do: false

  defp same?(_cx, _id, %{"bytes" => bytes}, content) when bytes != byte_size(content),
    do: false

  defp same?(cx, id, %{"path" => path}, content),
    do:
      match?(
        {:ok, %{"content" => ^content}},
        Context.call(cx, "agent.file", %{"agent" => id, "path" => path})
      )

  defp deleting(_there, _local, nil), do: []

  defp deleting(there, local, true) do
    there
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(local, &1))
    |> Enum.sort()
  end

  defp said(cx, answer) do
    counts =
      "Wrote #{length(answer["written"])}, kept #{length(answer["kept"])}" <>
        if(answer["deleted"] == [], do: ".", else: ", deleted #{length(answer["deleted"])}.")

    Context.puts(cx, counts)
    for path <- answer["skipped"], do: Context.puts(cx, "Left out #{path}: it isn't text.")
  end
end
