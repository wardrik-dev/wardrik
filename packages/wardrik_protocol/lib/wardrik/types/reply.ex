defmodule Wardrik.Reply do
  @moduledoc """
  An agent's answer: its `text`, the `message` it answers, and the `run` that wrote it.

  An agent answers `NO_REPLY` when a run finds nothing worth telling. Its notify targets aren't
  told of that answer.
  """

  @enforce_keys [:message, :run, :text]
  defstruct [:message, :run, :text]

  @type t() :: %__MODULE__{message: String.t(), run: String.t(), text: String.t()}

  @doc "Returns the assistant's text from `messages`, as a `wardrik.run.completed` event's data holds them."
  @spec text([map()]) :: String.t()
  def text(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "assistant"))
    |> Enum.flat_map(&Map.get(&1, "parts", []))
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join(& &1["content"])
  end

  @doc """
  Returns `true` if `text` is `NO_REPLY`, alone, even in code or bold.

      Wardrik.Reply.quiet?("`NO_REPLY`")
      #=> true
  """
  @spec quiet?(String.t()) :: boolean()
  def quiet?(text), do: Regex.match?(~r/\A[\s`*.]*NO_REPLY[\s`*.]*\z/, text)
end
