defmodule Wardrik.Conversation do
  @moduledoc """
  What a person, a model and the tools it called said to one another, in
  order: the history an agent keeps, and what a model call is asked.

      alias Wardrik.Conversation
      alias Wardrik.Conversation.User

      Conversation.new([User.new("Where is order 1001?")])

  A message is one of four structs, each a list of parts:

    * `Wardrik.Conversation.User` - what a person said
    * `Wardrik.Conversation.Assistant` - what the model said, its reasoning,
      and the tools it called
    * `Wardrik.Conversation.ToolResult` - what a tool answered a call with
    * `Wardrik.Conversation.ToolError` - why a call failed, or was refused

  A part is text (`Wardrik.Conversation.Text`), reasoning
  (`Wardrik.Conversation.Reasoning`), a call the model asked for
  (`Wardrik.Conversation.ToolCall`), a call its provider ran itself
  (`Wardrik.Conversation.ServerToolCall`), or media: by address
  (`Wardrik.Conversation.Uri`), by a provider's file id
  (`Wardrik.Conversation.File`), or inline (`Wardrik.Conversation.Blob`).

  Every message but a person's, and reasoning, carry a `provider` map: what
  the `Wardrik.LLM.Client` that made them keeps to send them back as they
  came, such as the signature of a model's reasoning. Nothing else reads it,
  and it is never written to the event log.
  """

  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolError
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Conversation.User

  defstruct messages: []

  @type message() :: User.t() | Assistant.t() | ToolResult.t() | ToolError.t()

  @type t() :: %__MODULE__{messages: [message()]}

  @doc "A conversation of `messages`, in order."
  @spec new([message()]) :: t()
  def new(messages \\ []) when is_list(messages), do: %__MODULE__{messages: messages}

  @doc "`conversation` with `messages`, one message or a list, added at its end."
  @spec append(t(), message() | [message()]) :: t()
  def append(%__MODULE__{messages: messages} = conversation, more) when is_list(more),
    do: %{conversation | messages: messages ++ more}

  def append(%__MODULE__{} = conversation, message), do: append(conversation, [message])

  @doc "The messages of `conversation`, in order."
  @spec to_list(t()) :: [message()]
  def to_list(%__MODULE__{messages: messages}), do: messages

  @doc "The text parts of a message joined, or `\"\"` for one with none."
  @spec text(message()) :: String.t()
  def text(%{parts: parts}), do: for(%Text{text: text} <- parts, into: "", do: text)

  @doc """
  What a turn that produced `messages` answered: the text of its last
  assistant message that said something. A turn that ended in tool calls
  alone leaves nothing to report, which is an empty answer, `\"\"`, rather
  than an error.
  """
  @spec answer([message()]) :: String.t()
  def answer(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %Assistant{} = message -> presence(text(message))
      _message -> nil
    end)
  end

  defp presence(""), do: nil
  defp presence(text), do: text
end
