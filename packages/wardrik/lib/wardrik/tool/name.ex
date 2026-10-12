defmodule Wardrik.Tool.Name do
  @moduledoc """
  A tool's name as an agent knows it, `github__create_issue`, and as it is
  shown, `github/create_issue`; and names written with `*` for any run of
  characters, `github/*`, which match a tool by either.

      glob = Wardrik.Tool.Name.glob("github/create_*")
      Wardrik.Tool.Name.match?(glob, "github__create_issue")  #=> true

  A glob is the written name split at its `*`s, plain data that can be kept
  in the store.
  """

  @type glob() :: [String.t()]

  @doc "The glob `source` writes."
  @spec glob(String.t()) :: glob()
  def glob(source), do: String.split(source, "*")

  @doc "How a tool the agent knows as `name` is shown: `server/tool` for an MCP server's."
  @spec shown(String.t()) :: String.t()
  def shown(name), do: String.replace(name, "__", "/", global: false)

  @doc "Whether `glob` names the tool the agent knows as `name`, as it is known or as it is shown."
  @spec match?(glob(), String.t()) :: boolean()
  def match?(glob, name), do: glob?(glob, name) or glob?(glob, shown(name))

  @doc "Whether `text` matches `glob`."
  @spec glob?(glob(), String.t()) :: boolean()
  def glob?([whole], text), do: text == whole

  def glob?([first | rest], text) do
    String.starts_with?(text, first) and
      follows?(rest, binary_slice(text, byte_size(first)..-1//1))
  end

  defp follows?([last], rest), do: String.ends_with?(rest, last)
  defp follows?(["" | parts], rest), do: follows?(parts, rest)

  defp follows?([part | parts], rest) do
    case :binary.match(rest, part) do
      {at, length} -> follows?(parts, binary_slice(rest, (at + length)..-1//1))
      :nomatch -> false
    end
  end
end
