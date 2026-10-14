defmodule WardrikDaemon.CLI.Command do
  @moduledoc """
  One command `wardrik` takes, defined once: its name, the job it is for, the
  arguments and options it takes, a line saying what it does, and what runs
  it.

  `WardrikDaemon.CLI.commands/0` lists them, and reading a command's
  arguments, its help and what a mistyped name was probably meant to be all
  come from that list. A command with no `:run` is one `bin/wardrik` runs
  itself, such as `start`, and is listed for its help.

  A command with `:json` also takes `--json`, and answers with one JSON
  document in place of its text.

  What runs a command is handed the words it was given, and its options: the
  switches given, and `:by`, the `Wardrik.Principal` who typed it, or `nil`,
  which a change it makes is recorded under in `Wardrik.Audit`.

  A command whose `:run` answers `:live` needs the terminal it came from,
  to write as it goes or to ask something: `bin/wardrik` runs it again over
  `bin/wardrikd rpc`, where `:live` runs it with that terminal.
  """

  alias WardrikConsole.Suggestion

  @enforce_keys [:name, :group, :summary]
  defstruct name: nil,
            group: nil,
            arguments: "",
            options: "",
            summary: nil,
            details: [],
            switches: [],
            count: {0, 0},
            run: nil,
            live: nil,
            json: nil

  @typedoc """
  What a command answers: what to print, or why it failed; `:usage` where
  its words do not make sense together; `:live` where it needs the terminal
  it came from; and, from `:live`, `:ok` or `:error` where it has printed all
  it has to.
  """
  @type answer() ::
          {:ok, Owl.Data.t() | (pos_integer() -> Owl.Data.t())}
          | {:error, Owl.Data.t() | :usage}
          | :live
          | :ok
          | :error

  @typedoc """
  A command. `:name` is its words, `"token create"`; `:group` is the job it
  is listed under, such as `"Decide"`; `:arguments` and
  `:options` are how its usage shows what follows them; `:switches` are its
  options as `OptionParser` reads them; and `:count` is how many words it
  takes after its name, fewest and most, `:any` for no most.
  """
  @type t() :: %__MODULE__{
          name: String.t(),
          group: String.t(),
          arguments: String.t(),
          options: String.t(),
          summary: String.t(),
          details: [String.t()],
          switches: keyword(atom()),
          count: {non_neg_integer(), non_neg_integer() | :any},
          run: ([String.t()], keyword() -> answer()) | nil,
          live: ([String.t()], keyword(), WardrikDaemon.CLI.Terminal.t() -> answer()) | nil,
          json: ([String.t()], keyword() -> {:ok, map()} | {:error, Owl.Data.t()}) | nil
        }

  @doc """
  The command `args` name, and the arguments after its name. A word that names
  only a group of commands, such as `token`, answers the group; a name that
  is not one answers what it is and the names nearest it.
  """
  @spec find([t()], [String.t()]) ::
          {:ok, t(), [String.t()]}
          | {:group, String.t(), [t()]}
          | {:unknown, String.t(), [String.t()]}
  def find(commands, args) do
    named = Enum.filter(commands, &List.starts_with?(args, words(&1)))

    case Enum.max_by(named, &length(words(&1)), fn -> nil end) do
      %__MODULE__{} = command -> {:ok, command, Enum.drop(args, length(words(command)))}
      nil -> nearest(commands, args)
    end
  end

  defp nearest(commands, [word | rest]) do
    case {Enum.filter(commands, &(hd(words(&1)) == word)), rest} do
      {[], _rest} ->
        firsts = commands |> Enum.map(&hd(words(&1))) |> Enum.uniq()
        {:unknown, word, Suggestion.closest(word, firsts)}

      {group, []} ->
        {:group, word, group}

      {group, [next | _rest]} ->
        seconds = for command <- group, [_word, second | _rest] <- [words(command)], do: second

        {:unknown, word <> " " <> next,
         Enum.map(Suggestion.closest(next, seconds), &"#{word} #{&1}")}
    end
  end

  defp words(%__MODULE__{name: name}), do: String.split(name)

  @doc """
  Reads what follows a command's name: its words, and its options as a
  keyword list, or its usage where they do not read.
  """
  @spec parse(t(), [String.t()]) :: {:ok, [String.t()], keyword()} | {:error, Owl.Data.t()}
  def parse(%__MODULE__{} = command, args) do
    case OptionParser.parse(args, strict: switches(command)) do
      {opts, words, []} ->
        if counted?(command.count, length(words)),
          do: {:ok, words, opts},
          else: {:error, usage(command)}

      {_opts, _words, [{switch, _value} | _rest]} ->
        {:error, ["wardrik #{command.name} takes no option #{switch}\n", usage(command)]}
    end
  end

  defp switches(%__MODULE__{json: nil, switches: switches}), do: switches
  defp switches(%__MODULE__{switches: switches}), do: [{:json, :boolean} | switches]

  defp counted?({fewest, :any}, count), do: count >= fewest
  defp counted?({fewest, most}, count), do: count in fewest..most

  @doc "How a command is written, as a line."
  @spec usage(t()) :: Owl.Data.t()
  def usage(%__MODULE__{} = command) do
    rest = Enum.reject([command.arguments, options(command)], &(&1 == ""))
    ["Usage: wardrik ", Owl.Data.tag(command.name, :bright) | Enum.map(rest, &[" ", &1])]
  end

  defp options(%__MODULE__{json: nil, options: options}), do: options
  defp options(%__MODULE__{options: ""}), do: "[--json]"
  defp options(%__MODULE__{options: options}), do: options <> " [--json]"

  @doc "A command in full: its usage, what it does, and anything more it says."
  @spec help(t()) :: Owl.Data.t()
  def help(%__MODULE__{details: details} = command) do
    more = if details == [], do: [], else: ["" | details]
    Enum.intersperse([usage(command), "", sentence(command.summary) | more], "\n")
  end

  defp sentence(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest <> "."

  @doc """
  Commands a line each, with what they take and what they do, the second
  column lined up where `width` has room for it and under the first where not.
  """
  @spec listing([t()], pos_integer()) :: Owl.Data.t()
  def listing(commands, width) do
    commands |> lines(layout(commands, width)) |> Enum.intersperse("\n")
  end

  @doc """
  Commands as `listing/2` gives them, under a heading for each group, in the
  order the groups first come in, with one column for them all.
  """
  @spec grouped([t()], pos_integer()) :: Owl.Data.t()
  def grouped(commands, width) do
    layout = layout(commands, width)

    commands
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(fn [%__MODULE__{group: group} | _rest] = chunk ->
      Enum.intersperse([Owl.Data.tag(group <> ":", :bright) | lines(chunk, layout)], "\n")
    end)
    |> Enum.intersperse("\n\n")
  end

  defp layout(commands, width) do
    column = commands |> Enum.map(&String.length(entry(&1))) |> Enum.max()
    beside? = commands |> Enum.map(&String.length(&1.summary)) |> Enum.max() <= width - column - 4
    {column, beside?}
  end

  defp lines(commands, {column, beside?}) do
    Enum.map(commands, fn command ->
      name = ["  ", Owl.Data.tag(command.name, :bright), rest(command)]

      if beside?,
        do: [
          name,
          String.duplicate(" ", column - String.length(entry(command)) + 2),
          command.summary
        ],
        else: [name, "\n      ", command.summary]
    end)
  end

  defp entry(command), do: command.name <> rest(command)
  defp rest(%__MODULE__{arguments: ""}), do: ""
  defp rest(%__MODULE__{arguments: arguments}), do: " " <> arguments
end
