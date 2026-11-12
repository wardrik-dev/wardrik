defmodule WardrikDaemon.CLI.Answers do
  @moduledoc """
  Answers setup questions: from `--set KEY=VALUE` and `--answers FILE` first, then the terminal.
  Without a terminal, a question no one answered takes `--yes`.

      # bootstrap.yaml, for wardrik init --answers bootstrap.yaml, or --answers - on stdin
      coding:
        claude: true
  """

  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.Setup
  alias WardrikDaemon.Setup.Question

  @doc "Returns the answers `--set` and `--answers` give, by question key."
  @spec given(map()) :: {:ok, %{String.t() => term()}} | {:error, String.t()}
  def given(flags) do
    with {:ok, read} <- read(flags[:answers]),
         {:ok, set} <- set(List.wrap(flags[:set])),
         do: {:ok, Map.merge(read, set)}
  end

  defp read(nil), do: {:ok, %{}}
  defp read("-"), do: parsed(IO.read(:stdio, :eof), "stdin")
  defp read(path), do: parsed(File.read(path), path)

  defp parsed({:ok, text}, from), do: parsed(text, from)
  defp parsed({:error, why}, from), do: {:error, "--answers #{from}: #{:file.format_error(why)}"}

  defp parsed(text, from) when is_binary(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, %{} = answers} -> {:ok, flat(answers, "")}
      {:ok, nil} -> {:ok, %{}}
      _unread -> {:error, "--answers #{from} isn't a YAML map of answers."}
    end
  end

  defp parsed(_eof, _from), do: {:ok, %{}}

  defp flat(map, prefix) do
    Enum.reduce(map, %{}, fn
      {key, %{} = nested}, flat -> Map.merge(flat, flat(nested, "#{prefix}#{key}."))
      {key, value}, flat -> Map.put(flat, "#{prefix}#{key}", value)
    end)
  end

  defp set(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, set} ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {:cont, {:ok, Map.put(set, key, value)}}
        [_none] -> {:halt, {:error, "--set #{pair}: is KEY=VALUE, as --set coding.claude=true."}}
      end
    end)
  end

  @doc "Returns a function that answers each question from `given`, the terminal, or `--yes`."
  @spec answer(Context.t(), %{String.t() => term()}, map()) :: Setup.answer()
  def answer(cx, given, flags) do
    fn %Question{key: key} = question ->
      case Map.fetch(given, key) do
        {:ok, value} -> Question.cast(question, value)
        :error -> asked(cx, question, flags)
      end
    end
  end

  defp asked(%Context{terminal: %{input?: true}}, question, _flags),
    do: {:ok, Owl.IO.confirm(message: question.label, default: question.default)}

  defp asked(_cx, _question, flags), do: {:ok, flags[:yes] == true}

  @doc "Returns a line for each given answer no question asked, as a typo in `--set` would be."
  @spec unasked(%{String.t() => term()}, [String.t()]) :: [String.t()]
  def unasked(given, asked) do
    for key <- Map.keys(given) -- asked,
        do: "Nothing asked #{key}: no step here offers it."
  end
end
