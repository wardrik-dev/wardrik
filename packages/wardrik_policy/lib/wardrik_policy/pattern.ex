defmodule WardrikPolicy.Pattern do
  @moduledoc """
  Tools named the way a person names them: `web_search`, `linear/list_issues`,
  every tool of a server as `linear/*`, or every tool at all as `*`.

      pattern = WardrikPolicy.Pattern.parse!("github/create_*")
      WardrikPolicy.Pattern.match?(pattern, "github__create_issue")  #=> true

  `*` stands for any run of characters. A pattern matches a tool by the name
  an agent knows it by, `github__create_issue` for an MCP server's, or by the
  name it is shown as, `github/create_issue`.

  A pattern may name what a call acts on too, in parentheses after the tool:
  `write_file(notes/*)`, `shell(git diff *)`. The argument is matched, with
  `*` as in the name, against each of the call's subjects, which its tool
  names from the arguments (see `c:Wardrik.Tool.subjects/2`), and never
  against the tool alone: `match?/2` is for a pattern without one, and
  `match?/3` for a subject.

  Or the parentheses may hold conditions on the call's arguments, which
  `WardrikPolicy.Condition` describes: `books/create_bill(amount > 500)`,
  `books/*(account: Payroll)`. They hold conditions where each of their
  comma-separated parts begins with an argument's name and then `:` and a
  space, `!=`, or a comparison, and what a call acts on where none does. A
  pattern with conditions names a whole call, `whole/3`, never a tool by
  its name alone.

  A pattern is plain data, so it can be written to the store with the agent
  it governs and read back on another node.
  """

  alias WardrikPolicy.Condition

  @enforce_keys [:source, :parts]
  defstruct [:source, :parts, :argument, :conditions]

  @type t() :: %__MODULE__{
          source: String.t(),
          parts: [String.t()],
          argument: [String.t()] | nil,
          conditions: [Condition.t()] | nil
        }

  @doc "The pattern `source` writes."
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(source) when is_binary(source) and source != "" do
    case Regex.run(~r/\A([^()]+)\((.*)\)\z/s, source) do
      [_whole, name, inner] ->
        pattern = %__MODULE__{source: source, parts: String.split(name, "*")}

        case Condition.parse(inner) do
          :subject -> {:ok, %{pattern | argument: String.split(inner, "*")}}
          {:ok, conditions} -> {:ok, %{pattern | conditions: conditions}}
          {:error, message} -> {:error, "#{inspect(source)}, which #{message}"}
        end

      nil ->
        if String.contains?(source, ["(", ")"]),
          do:
            {:error,
             "#{inspect(source)}, which is not a tool pattern; what a call acts on goes in " <>
               "parentheses after the tool, as shell(git status)"},
          else: {:ok, %__MODULE__{source: source, parts: String.split(source, "*")}}
    end
  end

  def parse(source), do: {:error, "#{inspect(source)} is not a tool pattern"}

  @doc "The pattern `source` writes, raising where it writes none."
  @spec parse!(String.t()) :: t()
  def parse!(source) do
    case parse(source) do
      {:ok, pattern} -> pattern
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "Whether the pattern has parentheses: what a call acts on, or conditions on its arguments."
  @spec argument?(t()) :: boolean()
  def argument?(%__MODULE__{argument: argument, conditions: conditions}),
    do: argument != nil or conditions != nil

  @doc "The server a `server/*` pattern names every tool of, or `nil`."
  @spec server(t()) :: String.t() | nil
  def server(%__MODULE__{source: source} = pattern) do
    if argument?(pattern), do: nil, else: served(source)
  end

  defp served(source) do
    case String.split(source, "/", parts: 2) do
      [server, "*"] when server != "" -> server
      _other -> nil
    end
  end

  @doc "How a tool the agent knows as `name` is shown: `server/tool` for an MCP server's."
  @spec shown(String.t()) :: String.t()
  def shown(name), do: String.replace(name, "__", "/", global: false)

  @doc """
  Whether the pattern names the tool the agent knows as `name`, as it is
  known or as it is shown. A pattern with an argument names no tool whole.
  """
  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{} = pattern, name), do: not argument?(pattern) and names?(pattern, name)

  @doc """
  Whether the pattern names the whole of a call to the tool the agent knows
  as `name`, with `arguments`: `:maybe` where it has conditions that may
  hold (see `WardrikPolicy.Condition`). A pattern naming what a call acts
  on names no call whole.
  """
  @spec whole(t(), String.t(), map()) :: Condition.held()
  def whole(%__MODULE__{argument: nil, conditions: nil} = pattern, name, _arguments),
    do: names?(pattern, name)

  def whole(%__MODULE__{argument: nil, conditions: conditions} = pattern, name, arguments),
    do: names?(pattern, name) and Condition.held(conditions, arguments)

  def whole(%__MODULE__{}, _name, _arguments), do: false

  @doc """
  Whether a pattern with an argument names `subject` of a call to the tool
  the agent knows as `name`.
  """
  @spec match?(t(), String.t(), String.t()) :: boolean()
  def match?(%__MODULE__{argument: nil}, _name, _subject), do: false

  def match?(%__MODULE__{argument: argument} = pattern, name, subject),
    do: names?(pattern, name) and glob?(argument, subject)

  defp names?(%__MODULE__{parts: parts}, name),
    do: glob?(parts, name) or glob?(parts, shown(name))

  @doc "Whether `text` matches `glob`, a pattern split at its `*`s."
  @spec glob?([String.t()], String.t()) :: boolean()
  def glob?([whole], text), do: text == whole

  def glob?([first | rest], name) do
    String.starts_with?(name, first) and
      follows?(rest, binary_slice(name, byte_size(first)..-1//1))
  end

  defp follows?([last], rest), do: String.ends_with?(rest, last)
  defp follows?(["" | parts], rest), do: follows?(parts, rest)

  defp follows?([part | parts], rest) do
    case :binary.match(rest, part) do
      {at, length} -> follows?(parts, binary_slice(rest, (at + length)..-1//1))
      :nomatch -> false
    end
  end

  defimpl String.Chars do
    def to_string(pattern), do: pattern.source
  end
end
