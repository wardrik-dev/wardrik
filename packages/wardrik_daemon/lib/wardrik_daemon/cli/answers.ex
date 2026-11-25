defmodule WardrikDaemon.CLI.Answers do
  @moduledoc """
  Answers setup questions: from `--set KEY=VALUE` and `--answers FILE` first, then the terminal.
  Without a terminal, a question no one answered takes its unattended answer: `--yes` for a yes
  or no question, and its default for a choice.

      # bootstrap.yaml, for wardrik init --answers bootstrap.yaml, or --answers - on stdin
      coding:
        claude: true
  """

  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.Setup

  @doc "Returns the answers `--set` and `--answers` give, by question key."
  @spec parse_given(map()) :: {:ok, %{String.t() => term()}} | {:error, String.t()}
  def parse_given(flags) do
    with {:ok, read} <- read(flags[:answers]),
         {:ok, set} <- set(List.wrap(flags[:set])),
         do: {:ok, Map.merge(read, set)}
  end

  defp read(nil), do: {:ok, %{}}
  defp read("-"), do: parse(IO.read(:stdio, :eof), "stdin")
  defp read(path), do: parse(File.read(path), path)

  defp parse({:ok, text}, from), do: parse(text, from)
  defp parse({:error, why}, from), do: {:error, "--answers #{from}: #{:file.format_error(why)}"}

  defp parse(text, from) when is_binary(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, %{} = answers} -> {:ok, flat(answers, "")}
      {:ok, nil} -> {:ok, %{}}
      _unread -> {:error, "--answers #{from} isn't a YAML map of answers."}
    end
  end

  defp parse(_eof, _from), do: {:ok, %{}}

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
    fn question ->
      case Map.fetch(given, question.key) do
        {:ok, value} -> asker(question).cast(question, value)
        :error -> ask(cx, question, flags)
      end
    end
  end

  defp ask(%Context{terminal: %{input?: true}}, question, _flags),
    do: {:ok, asker(question).ask_in_terminal(question)}

  defp ask(_cx, question, flags), do: {:ok, asker(question).answer_unattended(question, flags)}

  # Each kind of question is a struct whose module implements WardrikDaemon.Setup.Ask.
  defp asker(%module{}), do: module

  @doc "Returns a line for each given answer no question asked, as a typo in `--set` would be."
  @spec list_unasked(%{String.t() => term()}, [String.t()]) :: [String.t()]
  def list_unasked(given, asked) do
    for key <- Map.keys(given) -- asked,
        do: "Nothing asked #{key}: no step here offers it."
  end
end
