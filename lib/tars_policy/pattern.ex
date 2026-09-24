defmodule TarsPolicy.Pattern do
  @moduledoc """
  Tools named the way a person names them: `web_search`, `linear/list_issues`,
  every tool of a server as `linear/*`, or every tool at all as `*`.

      pattern = TarsPolicy.Pattern.parse!("github/create_*")
      TarsPolicy.Pattern.match?(pattern, "github__create_issue")  #=> true

  `*` stands for any run of characters. A pattern matches a tool by the name
  an agent knows it by, `github__create_issue` for an MCP server's, or by the
  name it is shown as, `github/create_issue`.

  A pattern is plain data, so it can be written to the store with the agent
  it governs and read back on another node.
  """

  @enforce_keys [:source, :parts]
  defstruct [:source, :parts]

  @type t() :: %__MODULE__{source: String.t(), parts: [String.t()]}

  @doc "The pattern `source` writes."
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(source) when is_binary(source) and source != "" do
    {:ok, %__MODULE__{source: source, parts: String.split(source, "*")}}
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

  @doc "The server a `server/*` pattern names every tool of, or `nil`."
  @spec server(t()) :: String.t() | nil
  def server(%__MODULE__{source: source}) do
    case String.split(source, "/", parts: 2) do
      [server, "*"] when server != "" -> server
      _other -> nil
    end
  end

  @doc "How a tool the agent knows as `name` is shown: `server/tool` for an MCP server's."
  @spec shown(String.t()) :: String.t()
  def shown(name), do: String.replace(name, "__", "/", global: false)

  @doc "Whether the pattern names the tool the agent knows as `name`, as it is known or as it is shown."
  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{parts: parts}, name), do: glob?(parts, name) or glob?(parts, shown(name))

  defp glob?([whole], name), do: name == whole

  defp glob?([first | rest], name) do
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
