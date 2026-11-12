defmodule WardrikDaemon.Setup do
  @moduledoc """
  The steps `wardrik init` takes after it writes its first files, and the changes they make.

  Each step is a `WardrikDaemon.Setup.Step`. It reads the machine and answers changes, and
  `apply/2` makes them. A change is one of:

    * `{:write, path, text}` - writes a file in the config directory, unless one is there.
    * `{:section, path, key, text}` - adds `text` to a YAML file in the config directory, unless it
      has `key` at its top level.
    * `{:command, command, why}` - a command for a person to run. Setup never runs one: it
      changes Wardrik's directories alone.
  """

  alias WardrikDaemon.Dirs
  alias WardrikDaemon.Setup.Machine
  alias WardrikDaemon.Setup.Question

  @type change() ::
          {:write, Path.t(), String.t()}
          | {:section, Path.t(), String.t(), String.t()}
          | {:command, String.t(), String.t()}

  @typedoc "What `apply/2` did with a change."
  @type done() :: {:wrote | :kept, Path.t()} | {:command, String.t(), String.t()}

  @typedoc "Answers a question, or says why it can't."
  @type answer() :: (Question.t() -> {:ok, term()} | {:error, String.t()})

  @steps [WardrikDaemon.Setup.Coding]

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
    with {:ok, planned} <- planned(steps, machine, answer) do
      planned = Enum.reverse(planned)
      {:ok, Enum.flat_map(planned, &elem(&1, 0)), Enum.flat_map(planned, &elem(&1, 1))}
    end
  end

  defp planned(steps, machine, answer) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, planned} ->
      found = step.detect(machine)

      case answered(step.questions(found), answer) do
        {:ok, answers} ->
          {:cont, {:ok, [{step.plan(found, answers), Map.keys(answers)} | planned]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp answered(questions, answer) do
    Enum.reduce_while(questions, {:ok, %{}}, fn %Question{key: key} = question, {:ok, answers} ->
      case answer.(question) do
        {:ok, value} -> {:cont, {:ok, Map.put(answers, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Makes `changes` in `dirs`. Returns what each did."
  @spec apply([change()], Dirs.t()) :: [done()]
  def apply(changes, %Dirs{} = dirs), do: Enum.map(changes, &made(&1, dirs))

  defp made({:write, name, text}, dirs) do
    path = config(dirs, name)

    if File.exists?(path) do
      {:kept, path}
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
      {:wrote, path}
    end
  end

  defp made({:section, name, key, text}, dirs) do
    path = config(dirs, name)
    written = File.read!(path)

    case YamlElixir.read_from_string(written) do
      {:ok, %{^key => _section}} ->
        {:kept, path}

      {:ok, _other} ->
        File.write!(path, [written, ended(written), "\n", text])
        {:wrote, path}
    end
  end

  defp made({:command, command, why}, _dirs), do: {:command, command, why}

  defp ended(text), do: if(String.ends_with?(text, "\n"), do: "", else: "\n")

  defp config(dirs, name) do
    {:ok, safe} = Path.safe_relative(name)
    Dirs.config(dirs, safe)
  end
end
