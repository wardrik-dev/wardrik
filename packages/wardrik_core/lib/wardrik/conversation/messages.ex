# The messages of a `Wardrik.Conversation`, one struct per author.

defmodule Wardrik.Conversation.User do
  @moduledoc "What a person said: text, and any media they gave with it."

  alias Wardrik.Conversation.Text

  @enforce_keys [:parts]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          parts: [
            Text.t()
            | Wardrik.Conversation.Uri.t()
            | Wardrik.Conversation.File.t()
            | Wardrik.Conversation.Blob.t()
          ]
        }

  @doc "A person saying `text`."
  @spec new(String.t()) :: t()
  def new(text) when is_binary(text), do: %__MODULE__{parts: [%Text{text: text}]}
end

defmodule Wardrik.Conversation.Assistant do
  @moduledoc """
  What the model said: its text, its reasoning, the calls it asked for, and
  the calls its provider ran for it, in the order it said them.
  """

  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolCall

  @enforce_keys [:parts]
  defstruct parts: [], provider: %{}

  @type part() ::
          Text.t()
          | Wardrik.Conversation.Reasoning.t()
          | ToolCall.t()
          | Wardrik.Conversation.ServerToolCall.t()
          | Wardrik.Conversation.Uri.t()
          | Wardrik.Conversation.File.t()
          | Wardrik.Conversation.Blob.t()

  @type t() :: %__MODULE__{parts: [part()], provider: map()}

  @doc "The model saying `text`, and nothing else."
  @spec new(String.t()) :: t()
  def new(text) when is_binary(text), do: %__MODULE__{parts: [%Text{text: text}]}

  @doc """
  The calls the model asked for, in order, each to be answered with a
  `Wardrik.Conversation.ToolResult` or a `Wardrik.Conversation.ToolError`.
  A call its provider ran is not among them.
  """
  @spec calls(t()) :: [ToolCall.t()]
  def calls(%__MODULE__{parts: parts}), do: for(%ToolCall{} = call <- parts, do: call)
end

defmodule Wardrik.Conversation.ToolResult do
  @moduledoc "What a tool answered the call `call_id`, to the tool `name`, with."

  @enforce_keys [:call_id, :name, :parts]
  defstruct [:call_id, :name, parts: [], provider: %{}]

  @type t() :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          parts: [Wardrik.Conversation.Text.t()],
          provider: map()
        }
end

defmodule Wardrik.Conversation.ToolError do
  @moduledoc "Why the call `call_id`, to the tool `name`, failed, or was refused."

  @enforce_keys [:call_id, :name, :parts]
  defstruct [:call_id, :name, parts: [], provider: %{}]

  @type t() :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          parts: [Wardrik.Conversation.Text.t()],
          provider: map()
        }
end
