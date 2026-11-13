defmodule WardrikDaemon.CLI.Command do
  @moduledoc """
  One `wardrik` command: its help, its options and what it runs.

      %WardrikDaemon.CLI.Command{
        name: "agent ls",
        shortcut: "ls",
        group: "Agents",
        arguments: "[QUERY]",
        switches: [all: :boolean],
        count: {0, :any},
        summary: "list the agents, and what each is doing",
        run: &ls/3
      }

  ## Fields

    * `:name` - required. The words that name it.
    * `:group` - required. Its heading in help.
    * `:summary` - required. One line on what it does.
    * `:arguments` - its arguments in help, as `AGENT MESSAGE`.
    * `:details` - more lines for its own help.
    * `:switches` - its options, as `OptionParser` takes them.
    * `:count` - how many arguments: a number, or `{least, :any}`. `0` unless set.
    * `:shortcut` - a shorter name, as `ls`.
    * `:run` - takes the arguments, switches and `WardrikDaemon.CLI.Context`. `nil` for a
      command `bin/wardrik` runs itself.
  """

  @enforce_keys [:name, :group, :summary]
  defstruct [
    :name,
    :group,
    :summary,
    :run,
    :shortcut,
    arguments: "",
    details: [],
    switches: [],
    count: 0
  ]

  @type run() :: ([String.t()], map(), WardrikDaemon.CLI.Context.t() ->
                    :ok | {:error, String.t()})

  @type t() :: %__MODULE__{
          name: String.t(),
          group: String.t(),
          summary: String.t(),
          run: run() | nil,
          shortcut: String.t() | nil,
          arguments: String.t(),
          details: [String.t()],
          switches: keyword(),
          count: non_neg_integer() | {non_neg_integer(), :any}
        }

  @doc "Returns the words that name `command`."
  @spec words(t()) :: [String.t()]
  def words(%__MODULE__{name: name}), do: String.split(name)

  @doc "Returns whether `command` takes `count` arguments."
  @spec takes?(t(), non_neg_integer()) :: boolean()
  def takes?(%__MODULE__{count: {least, :any}}, count), do: count >= least
  def takes?(%__MODULE__{count: expected}, count), do: count == expected

  @doc "Returns how `command` is typed, as `agent show AGENT [--json]`."
  @spec usage(t()) :: String.t()
  def usage(%__MODULE__{} = command) do
    [command.name, command.arguments, options(command.switches)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp options(switches) do
    Enum.map_join(switches, " ", fn
      {name, :boolean} -> "[--#{flag(name)}]"
      {name, _type} -> "[--#{flag(name)} #{String.upcase(Atom.to_string(name))}]"
    end)
  end

  defp flag(name), do: String.replace(Atom.to_string(name), "_", "-")
end
