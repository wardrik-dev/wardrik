defmodule WardrikDaemon.CLI.Completion do
  @moduledoc false

  alias WardrikDaemon.CLI.Command

  @programs ~w(wardrik rik)
  @always ~w(--json --help)

  @doc "Returns the completion script for `shell` over `commands`, or `:error` for a shell it doesn't know."
  @spec script(String.t(), [Command.t()]) :: {:ok, String.t()} | :error
  def script("bash", commands), do: {:ok, bash(commands)}

  def script("zsh", commands),
    do: {:ok, "autoload -U +X bashcompinit && bashcompinit\n" <> bash(commands)}

  def script("fish", commands), do: {:ok, fish(commands)}
  def script(_shell, _commands), do: :error

  defp bash(commands) do
    command_cases =
      commands
      |> sorted()
      |> Enum.map(fn command ->
        patterns =
          command
          |> names()
          |> Enum.map_join("|", &~s("#{&1}"|"#{&1} "*))

        ~s(    #{patterns}\) words="#{Enum.join(flags(command), " ")}" ;;)
      end)

    prefix_cases =
      commands
      |> prefixes()
      |> Enum.map(fn prefix ->
        ~s(    "#{prefix}"\) words="#{Enum.join(next(commands, prefix), " ")}" ;;)
      end)

    cases = command_cases ++ prefix_cases

    """
    _wardrik() {
      local cur="${COMP_WORDS[COMP_CWORD]}" line="${COMP_WORDS[*]:1:COMP_CWORD-1}" words=""
      case "$line" in
    #{Enum.join(cases, "\n")}
      esac
      COMPREPLY=($(compgen -W "$words" -- "$cur"))
    }
    complete -F _wardrik #{Enum.join(@programs, " ")}
    """
  end

  defp fish(commands) do
    lines =
      for program <- @programs,
          line <- fish_lines(commands, program),
          do: line

    """
    function __wardrik_words
      set -l words (commandline -opc)
      set -l typed (string join " " (string match -v -- "-*" $words[2..-1]))
      echo "+$typed"
    end

    #{Enum.join(lines, "\n")}
    """
  end

  defp fish_lines(commands, program) do
    ["complete -c #{program} -f"] ++
      for(
        prefix <- prefixes(commands),
        word <- next(commands, prefix),
        do:
          "complete -c #{program} -n 'test (__wardrik_words) = \"+#{prefix}\"' -a #{word}" <>
            described(commands, prefix, word)
      ) ++
      for(
        command <- commands,
        name <- names(command),
        "--" <> flag <- flags(command),
        do:
          "complete -c #{program} -n 'string match -q -- \"+#{name}*\" (__wardrik_words)' -l #{flag}"
      )
  end

  defp described(commands, prefix, word) do
    name = String.trim("#{prefix} #{word}")

    case Enum.find(commands, &(&1.name == name)) do
      nil -> ""
      command -> " -d " <> quoted(command.summary)
    end
  end

  defp quoted(text), do: "'" <> String.replace(text, "'", "\\'") <> "'"

  defp names(%Command{name: name, shortcut: nil}), do: [name]
  defp names(%Command{name: name, shortcut: shortcut}), do: [name, shortcut]

  defp sorted(commands), do: Enum.sort_by(commands, &(-length(Command.words(&1))))

  defp prefixes(commands) do
    commands
    |> Enum.flat_map(fn command ->
      words = Command.words(command)

      for count <- 0..(length(words) - 1) do
        words
        |> Enum.take(count)
        |> Enum.join(" ")
      end
    end)
    |> Enum.uniq()
  end

  defp next(commands, prefix) do
    taken = String.split(prefix)
    depth = length(taken)

    words =
      for command <- commands,
          command_words = Command.words(command),
          {^taken, [word | _rest]} <- [Enum.split(command_words, depth)],
          do: word

    shortcuts =
      if prefix == "", do: ["help" | for(%{shortcut: s} <- commands, s, do: s)], else: []

    Enum.uniq(words ++ shortcuts)
  end

  defp flags(%Command{switches: switches}),
    do:
      Enum.map(switches, fn {name, _type} ->
        "--" <> String.replace(Atom.to_string(name), "_", "-")
      end) ++ @always
end
