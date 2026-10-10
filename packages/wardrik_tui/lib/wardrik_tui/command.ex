defmodule WardrikTUI.Command do
  @moduledoc """
  The slash commands `WardrikTUI.App` understands, defined once.

  Each command carries its name and aliases, a usage line, a one-line
  summary and a parser for its argument, and for the palette a label, the
  arguments it is given step by step, when it is available, and the key that
  does the same. `parse/2` reads a whole line typed at the prompt, `help/0`
  lists every command for `/help`, `complete/1` finishes a partly typed name,
  `suggest/1` names the closest commands to a word that is not one, and
  `palette/1` lists the commands available in a context.

  A line that is not a command is a question for the agent, unless a turn is
  parked: then a bare `y` or `n` answers it, `y 2`, `n 2 reason` and `y all`
  pick among several parked calls the way `/approve` and `/deny` do, and only
  a bare word counts, so a question that happens to start with "no" is still a
  question. A line starting with `//` is a question too, with one slash taken
  off, which is how text that begins with a slash is sent as typed.

  `/connect` and `/move` with nothing after them, and `/move NAME` without a
  node, parse as such: the app then asks for what is missing.
  """

  @enforce_keys [:name, :usage, :summary, :parse, :label]
  defstruct name: nil,
            aliases: [],
            usage: nil,
            summary: nil,
            parse: nil,
            label: nil,
            arguments: [],
            available: nil,
            shortcut: nil

  @typedoc "One command: how it is named, what it takes, and what it means."
  @type t() :: %__MODULE__{
          name: String.t(),
          aliases: [String.t()],
          usage: String.t(),
          summary: String.t(),
          parse: (String.t() | nil -> parsed() | :usage),
          label: String.t(),
          arguments: [step()],
          available: (context() -> boolean()) | nil,
          shortcut: String.t() | nil
        }

  @typedoc """
  One argument the palette collects: an agent or a node picked from a list, a
  parked call picked by number, or text typed.
  """
  @type step() :: :agent | :node | :call | :text

  @typedoc """
  What decides availability: whether a turn is running or parked, how many
  calls are parked, whether a removal waits on `/confirm`, how many nodes the
  cluster has, and how many agents need attention.
  """
  @type context() :: %{
          busy?: boolean(),
          parked: non_neg_integer(),
          confirm?: boolean(),
          nodes: pos_integer(),
          attention: non_neg_integer()
        }

  @typedoc "Which parked call a decision is for: the only one, one by number, or every one."
  @type selector() :: nil | :all | String.t()

  @typedoc "The `key=value` words a command was given."
  @type options() :: %{String.t() => String.t()}

  @typedoc "What a line typed at the prompt means."
  @type parsed() ::
          :blank
          | :quit
          | :fleet
          | :help
          | :confirm
          | {:stop, String.t() | nil}
          | {:shutdown, String.t()}
          | {:rm, String.t(), boolean()}
          | {:approve, selector(), String.t() | nil}
          | {:deny, selector(), String.t() | nil}
          | {:spawn, String.t(), options(), String.t() | nil, :attach | :background}
          | {:move, String.t() | nil, options()}
          | {:connect, String.t() | nil}
          | {:filter, String.t() | nil}
          | :next
          | {:find, String.t() | nil}
          | :tools
          | {:copy, :answer | :code}
          | {:ask, String.t()}
          | {:usage, String.t()}
          | {:unknown, String.t()}

  @doc "Every command, in the order `/help` lists them."
  @spec all() :: [t()]
  def all do
    [
      %__MODULE__{
        name: "/spawn",
        label: "Spawn an agent",
        arguments: [:text],
        usage: "/spawn NAME [node=N] [--bg] [-- prompt]",
        summary: "start an agent and attach to it; --bg stays here; the prompt is sent as is",
        parse: &spawn_agent/1
      },
      %__MODULE__{
        name: "/connect",
        label: "Connect to an agent",
        arguments: [:agent],
        usage: "/connect [NAME]",
        summary: "attach to an agent; alone, or given part of a name, pick from a list",
        parse: &connect/1
      },
      %__MODULE__{
        name: "/move",
        label: "Move an agent to another node",
        arguments: [:agent, :node],
        available: &(&1.nodes > 1),
        usage: "/move [NAME [node=N]]",
        summary: "restart an agent on another node, as it was; asks first mid-turn",
        parse: &move/1
      },
      %__MODULE__{
        name: "/stop",
        label: "Stop the turn",
        available: & &1.busy?,
        shortcut: "Esc",
        usage: "/stop [NAME | PREFIX/]",
        summary: "interrupt this agent, another, or every agent under a prefix",
        parse: &stop/1
      },
      %__MODULE__{
        name: "/shutdown",
        label: "Shut an agent down",
        arguments: [:agent],
        usage: "/shutdown NAME",
        summary: "stop an agent and keep its conversation; /spawn brings it back",
        parse: &shutdown/1
      },
      %__MODULE__{
        name: "/rm",
        label: "Remove an agent and its conversation",
        arguments: [:agent],
        usage: "/rm NAME | PREFIX/ [--yes]",
        summary: "delete an agent and its conversation, after showing what goes",
        parse: &rm/1
      },
      %__MODULE__{
        name: "/confirm",
        label: "Go ahead with the removal shown",
        available: & &1.confirm?,
        usage: "/confirm",
        summary: "go ahead with the removal shown",
        parse: bare(:confirm)
      },
      %__MODULE__{
        name: "/fleet",
        label: "Show the fleet panel",
        usage: "/fleet",
        summary: "show the fleet panel and move into it",
        parse: bare(:fleet)
      },
      %__MODULE__{
        name: "/filter",
        label: "Filter the fleet panel",
        arguments: [:text],
        usage: "/filter [QUERY]",
        summary: "narrow the panel by text, name:, org:, user:, node:, status: or attention",
        parse: &filter/1
      },
      %__MODULE__{
        name: "/find",
        label: "Search the transcript",
        usage: "/find [TEXT]",
        summary: "search the transcript for text; / in the transcript does too",
        parse: &search/1
      },
      %__MODULE__{
        name: "/tools",
        label: "Inspect a tool call",
        usage: "/tools",
        summary: "pick a tool call of this conversation and see its arguments and output in full",
        parse: bare(:tools)
      },
      %__MODULE__{
        name: "/copy",
        label: "Copy the last answer",
        usage: "/copy [code]",
        summary: "copy the last answer to the clipboard, or its last code block",
        parse: &copy/1
      },
      %__MODULE__{
        name: "/next",
        label: "Next agent needing attention",
        available: &(&1.attention > 0),
        usage: "/next",
        summary: "connect to the next agent needing attention",
        parse: bare(:next)
      },
      %__MODULE__{
        name: "/approve",
        label: "Approve a parked call",
        arguments: [:call],
        available: &(&1.parked > 0),
        aliases: ["/y"],
        usage: "/approve [N | all] [note]",
        summary: "approve the parked call, or one by number, with a note; y too",
        parse: &approve/1
      },
      %__MODULE__{
        name: "/deny",
        label: "Deny a parked call",
        arguments: [:call],
        available: &(&1.parked > 0),
        aliases: ["/n"],
        usage: "/deny [N | all] [reason]",
        summary: "deny the parked call, or one by number, saying why; n too",
        parse: &deny/1
      },
      %__MODULE__{
        name: "/quit",
        label: "Quit",
        shortcut: "Ctrl-D",
        aliases: ["/exit"],
        usage: "/quit",
        summary: "leave",
        parse: bare(:quit)
      },
      %__MODULE__{
        name: "/help",
        label: "Every key and command",
        usage: "/help",
        summary: "every key and command, searchable; Enter there runs a command",
        parse: bare(:help)
      }
    ]
  end

  @doc "The command a word names, by name or alias, or `nil`."
  @spec find(String.t()) :: t() | nil
  def find(word), do: Enum.find(all(), &(word == &1.name or word in &1.aliases))

  @doc "Every command name, aliases included."
  @spec names() :: [String.t()]
  def names, do: Enum.flat_map(all(), &[&1.name | &1.aliases])

  @doc "Each command's usage and summary, for `/help`."
  @spec help() :: [{String.t(), String.t()}]
  def help, do: Enum.map(all(), &{&1.usage, &1.summary})

  @doc "The commands available in `context`, in the order `/help` lists them."
  @spec palette(context()) :: [t()]
  def palette(context), do: Enum.filter(all(), &available?(&1, context))

  @doc "Whether `command` can be run in `context`."
  @spec available?(t(), context()) :: boolean()
  def available?(%__MODULE__{available: nil}, _context), do: true
  def available?(%__MODULE__{available: available}, context), do: available.(context)

  @doc "The command names that begin with `word`."
  @spec complete(String.t()) :: [String.t()]
  def complete(word),
    do: all() |> Enum.map(& &1.name) |> Enum.filter(&String.starts_with?(&1, word))

  @doc "The commands closest to a word that names none, nearest first."
  @spec suggest(String.t()) :: [String.t()]
  def suggest(word), do: WardrikConsole.Suggestion.closest(word, Enum.map(all(), & &1.name))

  @doc """
  Reads one line typed at the prompt.

  `parked?` says whether a turn is waiting on a decision, which is when a bare
  `y` or `n` is an answer rather than a question.
  """
  @spec parse(String.t(), boolean()) :: parsed()
  def parse(line, parked? \\ false) do
    case String.trim(line) do
      "" -> :blank
      "//" <> rest -> {:ask, "/" <> rest}
      "/" <> _rest = slash -> slash(slash)
      text -> answer(text, parked?)
    end
  end

  defp slash(line) do
    [word | rest] = String.split(line, " ", parts: 2)
    argument = rest |> List.first("") |> String.trim() |> presence()

    case find(word) do
      nil ->
        {:unknown, word}

      command ->
        case command.parse.(argument) do
          :usage -> {:usage, command.name}
          parsed -> parsed
        end
    end
  end

  # -- each command's argument ------------------------------------------------

  defp bare(parsed), do: fn argument -> if(argument == nil, do: parsed, else: :usage) end

  defp search(argument), do: {:find, argument}

  defp copy(nil), do: {:copy, :answer}
  defp copy("code"), do: {:copy, :code}
  defp copy(_argument), do: :usage

  defp connect(nil), do: {:connect, nil}
  defp connect(argument), do: one_word(argument, &{:connect, &1})
  defp filter(argument), do: {:filter, argument}
  defp shutdown(argument), do: one_word(argument, &{:shutdown, &1})

  defp stop(nil), do: {:stop, nil}
  defp stop(argument), do: one_word(argument, &{:stop, &1})

  defp one_word(nil, _build), do: :usage

  defp one_word(argument, build) do
    case String.split(argument) do
      [word] -> build.(word)
      _other -> :usage
    end
  end

  defp rm(nil), do: :usage

  defp rm(argument) do
    case String.split(argument) do
      [target, "--yes"] -> {:rm, target, true}
      [target] -> {:rm, target, false}
      _other -> :usage
    end
  end

  # `/approve 2 only this once` approves the second call with a note for the
  # agent, and `/deny 2 too risky` denies it saying why; without a number or
  # `all`, they answer the only one, and the rest is the note or the reason.
  defp approve(argument) do
    {selector, note} = said(argument)
    {:approve, selector, note}
  end

  defp deny(argument) do
    {selector, reason} = said(argument)
    {:deny, selector, reason}
  end

  defp said(nil), do: {nil, nil}

  defp said(argument) do
    case String.split(argument, " ", parts: 2) do
      [word] -> said(selector(word), if(selector(word), do: nil, else: word))
      [word, rest] -> said(selector(word), if(selector(word), do: rest, else: argument))
    end
  end

  defp said(selector, text), do: {selector, text && String.trim(text)}

  defp selector("all"), do: :all
  defp selector(word), do: if(word =~ ~r/^\d+$/, do: word, else: nil)

  # A name, then `key=value` options and `--bg`. The prompt is everything
  # after ` -- `, kept as typed; without the delimiter it starts at the first
  # word that is neither, also kept as typed.
  @background "--bg"

  defp spawn_agent(nil), do: :usage

  defp spawn_agent(argument) do
    case String.split(argument, ~r/\s--(\s|$)/, parts: 2) do
      [head, prompt] -> spawn_named(head, presence(String.trim(prompt)))
      [head] -> spawn_unmarked(head)
    end
  end

  defp spawn_unmarked(argument) do
    tokens = Regex.scan(~r/\S+/, argument, return: :index) |> List.flatten()
    [{_start, _length} = _name | words] = tokens

    case Enum.find_index(words, fn {start, length} ->
           word = binary_part(argument, start, length)
           not option?(word) and word != @background
         end) do
      nil ->
        spawn_named(argument, nil)

      index ->
        {start, _length} = Enum.at(words, index)
        head = binary_part(argument, 0, start)
        prompt = argument |> binary_part(start, byte_size(argument) - start) |> String.trim()
        spawn_named(head, prompt)
    end
  end

  defp spawn_named(head, prompt) do
    with {:ok, name, options, flags} <- named(head, [@background]) do
      {:spawn, name, options, prompt, if(@background in flags, do: :background, else: :attach)}
    end
  end

  # A name and options only; anything else is a mistake rather than a prompt.
  # Without a name, or a node, the app asks for it.
  defp move(nil), do: {:move, nil, %{}}

  defp move(argument),
    do: with({:ok, name, options, []} <- named(argument), do: {:move, name, options})

  # A name, then `key=value` options and any of `flags`, in any order.
  defp named(text, flags \\ []) do
    case String.split(text) do
      [name | words] ->
        {given, rest} = Enum.split_with(words, &(&1 in flags))

        if name not in flags and Enum.all?(rest, &option?/1),
          do: {:ok, name, Map.new(rest, &option/1), Enum.uniq(given)},
          else: :usage

      [] ->
        :usage
    end
  end

  defp option?(word), do: String.contains?(word, "=")
  defp option(word), do: word |> String.split("=", parts: 2) |> List.to_tuple()

  defp presence(""), do: nil
  defp presence(text), do: text

  # -- what is not a command --------------------------------------------------

  defp answer(text, false), do: {:ask, text}

  defp answer(text, true) do
    case String.split(text, " ", parts: 2) do
      [word] -> bare_answer(word, nil, text)
      [word, rest] -> bare_answer(word, String.trim(rest), text)
    end
  end

  defp bare_answer(word, rest, text) do
    case {String.downcase(word), rest} do
      {yes, nil} when yes in ["y", "yes"] ->
        {:approve, nil, nil}

      {yes, rest} when yes in ["y", "yes"] ->
        if(selector(rest), do: {:approve, selector(rest), nil}, else: {:ask, text})

      {no, rest} when no in ["n", "no"] ->
        deny(rest)

      _other ->
        {:ask, text}
    end
  end
end
