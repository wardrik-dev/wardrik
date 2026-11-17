defmodule WardrikDaemon.Setup do
  @moduledoc """
  The steps `wardrik init` takes after it writes its first files, and the changes they make.

  Each step is a `WardrikDaemon.Setup.Step`. It reads the machine and answers changes, and
  `apply/2` makes them. A change is one of:

    * `{:write, path, text}` - writes a file in the config directory, unless one is there.
    * `{:entry, path, section, name, text}` - adds `name`, holding the YAML `text`, under the
      top-level `section` of a YAML file in the config directory, unless `name` is there. A section
      written on one line, as `harnesses: {}`, takes no entry: `apply/2` says to add it by hand.
    * `{:command, command, why}` - a command for a person to run. Setup never runs one: it
      changes Wardrik's directories alone.
  """

  alias WardrikDaemon.Dirs
  alias WardrikDaemon.Setup.Machine
  alias WardrikDaemon.Setup.Question

  @type change() ::
          {:write, Path.t(), String.t()}
          | {:entry, Path.t(), String.t(), String.t(), String.t()}
          | {:command, String.t(), String.t()}

  @typedoc "What `apply/2` did with a change."
  @type done() :: {:wrote | :kept, Path.t()} | {:command, String.t(), String.t()}

  @typedoc "Answers a question, or says why it can't."
  @type answer() :: (Question.t() -> {:ok, term()} | {:error, String.t()})

  @steps [WardrikDaemon.Setup.ClaudeCode]

  @doc "Returns the steps `wardrik init` takes, in order."
  @spec steps() :: [module()]
  def steps, do: @steps

  @doc """
  Returns the changes `steps` answer on `machine`, with `answer` answering their questions, and
  the key of each question asked.
  """
  @spec plan([module()], Machine.t(), answer()) ::
          {:ok, [change()], [String.t()]} | {:error, String.t()}
  def plan(steps, %Machine{} = machine, answer) do
    with {:ok, planned} <- handle_plan(steps, machine, answer) do
      planned = Enum.reverse(planned)
      {:ok, Enum.flat_map(planned, &elem(&1, 0)), Enum.flat_map(planned, &elem(&1, 1))}
    end
  end

  defp handle_plan(steps, machine, answer) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, planned} ->
      found = step.detect(machine)

      case answer(step.questions(found), answer) do
        {:ok, answers} ->
          {:cont, {:ok, [{step.plan(found, answers), Map.keys(answers)} | planned]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp answer(questions, answer) do
    Enum.reduce_while(questions, {:ok, %{}}, fn %Question{key: key} = question, {:ok, answers} ->
      case answer.(question) do
        {:ok, value} -> {:cont, {:ok, Map.put(answers, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Makes `changes` in `dirs`. Returns what each did, or why one can't be made."
  @spec apply([change()], Dirs.t()) :: {:ok, [done()]} | {:error, String.t()}
  def apply(changes, %Dirs{} = dirs) do
    with {:ok, done} <- make(changes, dirs, []), do: {:ok, Enum.reverse(done)}
  end

  defp make([], _dirs, done), do: {:ok, done}

  defp make([change | changes], dirs, done) do
    case make(change, dirs) do
      {:error, _why} = error -> error
      made -> make(changes, dirs, [made | done])
    end
  end

  defp make({:write, name, text}, dirs) do
    path = config(dirs, name)

    if File.exists?(path) do
      {:kept, path}
    else
      path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(path, text)
      {:wrote, path}
    end
  end

  defp make({:entry, name, section, key, text}, dirs) do
    path = config(dirs, name)
    written = File.read!(path)
    {:ok, read} = YamlElixir.read_from_string(written)
    entry = indent("#{key}:\n" <> indent(text))

    case Map.get(read || %{}, section) do
      %{^key => _entry} ->
        {:kept, path}

      nil ->
        File.write!(path, [written, finish(written), "\n#{section}:\n", entry])
        {:wrote, path}

      _section ->
        case Regex.split(~r/^#{section}:[ \t]*(#.*)?\n/m, written,
               parts: 2,
               include_captures: true
             ) do
          [before, line, rest] ->
            File.write!(path, [before, line, entry, rest])
            {:wrote, path}

          [_one_line] ->
            {:error,
             "#{path} writes #{section} on one line. Add this under it by hand:\n\n" <> entry}
        end
    end
  end

  defp make({:command, command, why}, _dirs), do: {:command, command, why}

  defp finish(text), do: if(String.ends_with?(text, "\n"), do: "", else: "\n")

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "  " <> line
    end)
  end

  defp config(dirs, name) do
    {:ok, safe} = Path.safe_relative(name)
    Dirs.config(dirs, safe)
  end
end
