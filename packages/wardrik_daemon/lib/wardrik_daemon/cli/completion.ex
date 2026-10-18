defmodule WardrikDaemon.CLI.Completion do
  @moduledoc """
  Shell completion for `wardrik`, from `WardrikDaemon.CLI.commands/0`.

  `script/1` is what `wardrik completion SHELL` prints, for bash, zsh or
  fish. As a word is completed, the script asks `wardrik __complete` with the
  words so far after the command's name, the one being completed last, and
  offers what `candidates/3` answers: command names, a command's options,
  the keys of the agents running for a `KEY`, the calls an agent waits on for
  a `CALL`, the nodes running a daemon for a `NODE`, and a query's words for
  `ls`. Where no daemon is running, `bin/wardrik` answers on a VM of its own,
  which knows no agents.

  The scripts complete `rik` as well as `wardrik`, and ask whichever was typed.
  """

  alias WardrikDaemon.CLI.Command

  @typedoc "What only a running daemon knows: the agents' keys, the calls an agent waits on, and its nodes."
  @type known() :: %{
          keys: (-> [String.t()]),
          calls: (String.t() -> [String.t()]),
          nodes: (-> [String.t()])
        }

  @shells ~w(bash zsh fish)
  @query ~w(status:idle status:running status:parked attention name: org: user: node:)

  @doc "The shells `script/1` writes for."
  @spec shells() :: [String.t()]
  def shells, do: @shells

  @doc """
  What can follow `words`, whose last is the word being completed, perhaps
  empty, given what `known` knows; only those starting with that word.
  """
  @spec candidates([String.t()], [Command.t()], known()) :: [String.t()]
  def candidates([], commands, known), do: candidates([""], commands, known)

  def candidates(words, commands, known) do
    {typed, [current]} = Enum.split(words, -1)

    commands
    |> following(without_node(typed), current, known)
    |> Enum.filter(&String.starts_with?(&1, current))
  end

  # --node NAME is the script's, before any command.
  defp without_node(["--node", _name | rest]), do: without_node(rest)
  defp without_node(["--node=" <> _name | rest]), do: without_node(rest)
  defp without_node(typed), do: typed

  defp following(commands, [], _current, _known), do: names(commands, [])

  defp following(commands, typed, current, known) do
    case Command.find(commands, typed) do
      {:ok, %Command{name: "help"}, rest} -> names(commands, rest)
      {:ok, command, rest} -> after_name(command, rest, current, known)
      _group_or_unknown -> names(commands, typed)
    end
  end

  # The first words of every command, or the second words of a group.
  defp names(commands, []), do: commands |> Enum.map(&hd(words(&1))) |> Enum.uniq()

  defp names(commands, [group]) do
    for %Command{} = command <- commands, [^group, second | _rest] <- [words(command)], do: second
  end

  defp names(_commands, _typed), do: []

  defp words(%Command{name: name}), do: String.split(name)

  defp after_name(command, _rest, "-" <> _option, _known), do: options(command)

  defp after_name(command, rest, _current, known) do
    {positional, awaiting?} = positional(rest, switches(command))

    if awaiting?,
      do: [],
      else: values(placeholder(command, length(positional)), command, positional, known)
  end

  defp switches(%Command{json: nil, switches: switches}), do: switches
  defp switches(%Command{switches: switches}), do: [{:json, :boolean} | switches]

  defp options(command) do
    for({switch, _type} <- switches(command), do: "--" <> dashed(switch)) ++ ["--help"]
  end

  defp dashed(switch), do: switch |> to_string() |> String.replace("_", "-")

  # The words that are not options, and whether the last word is an option
  # still waiting for its value.
  defp positional(rest, switches), do: positional(rest, switches, [], false)

  defp positional([], _switches, words, awaiting?), do: {Enum.reverse(words), awaiting?}

  defp positional([_value | rest], switches, words, true),
    do: positional(rest, switches, words, false)

  defp positional(["--" <> option | rest], switches, words, false),
    do: positional(rest, switches, words, value?(option, switches))

  defp positional([word | rest], switches, words, false),
    do: positional(rest, switches, [word | words], false)

  defp value?(option, switches),
    do: Enum.any?(switches, fn {switch, type} -> type == :string and dashed(switch) == option end)

  # The name its usage gives the word at `index`, the last again for a
  # command that takes any number, and none past the most it takes.
  defp placeholder(%Command{arguments: arguments, count: {_fewest, most}}, index) do
    names = ~r/[A-Z_]+/ |> Regex.scan(arguments) |> List.flatten()

    cond do
      most != :any and index >= most -> nil
      index < length(names) -> Enum.at(names, index)
      most == :any -> List.last(names)
      true -> nil
    end
  end

  defp values(name, _command, _positional, known) when name in ["KEY", "PREFIX"],
    do: known.keys.()

  defp values("QUERY", _command, _positional, known), do: @query ++ known.keys.()
  defp values("SHELL", _command, _positional, _known), do: @shells
  defp values("NODE", _command, _positional, known), do: known.nodes.()

  defp values("CALL", command, positional, known) do
    case Enum.at(positional, key_index(command)) do
      nil -> []
      key -> known.calls.(key)
    end
  end

  defp values(_name, _command, _positional, _known), do: []

  defp key_index(%Command{arguments: arguments}) do
    ~r/[A-Z_]+/ |> Regex.scan(arguments) |> List.flatten() |> Enum.find_index(&(&1 == "KEY"))
  end

  @doc "The completion script for `shell`, one of `shells/0`."
  @spec script(String.t()) :: String.t()
  def script("bash") do
    """
    # wardrik and rik completion for bash. Install it with:
    #   wardrik completion bash > ~/.local/share/bash-completion/completions/wardrik
    _wardrik() {
      local IFS=$'\\n'
      COMPREPLY=($("${COMP_WORDS[0]}" __complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2> /dev/null))
    }
    complete -o default -F _wardrik wardrik rik
    """
  end

  def script("zsh") do
    """
    #compdef wardrik rik
    # wardrik and rik completion for zsh. Install it with:
    #   wardrik completion zsh > "${fpath[1]}/_wardrik"
    # or load it in .zshrc after compinit with: source <(wardrik completion zsh)
    _wardrik() {
      local -a candidates
      candidates=(${(f)"$(${words[1]} __complete "${(@)words[2,CURRENT]}" 2> /dev/null)"})
      compadd -- $candidates
    }

    if [ "$funcstack[1]" = "_wardrik" ]; then
      _wardrik "$@"
    else
      compdef _wardrik wardrik rik
    fi
    """
  end

  def script("fish") do
    """
    # wardrik and rik completion for fish. Install it with:
    #   wardrik completion fish > ~/.config/fish/completions/wardrik.fish
    for name in wardrik rik
        complete -c $name -f -a "($name __complete (commandline -opc)[2..-1] (commandline -ct) 2> /dev/null)"
    end
    """
  end
end
