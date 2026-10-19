# The parts of a `Wardrik.Conversation`'s messages, one struct per kind.

defmodule Wardrik.Conversation.Text do
  @moduledoc "Text, as a person, the model or a tool said it."

  @enforce_keys [:text]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{text: String.t()}
end

defmodule Wardrik.Conversation.Reasoning do
  @moduledoc """
  What the model reasoned before it answered, with what its client keeps to
  send it back, such as its signature, as `provider`.
  """

  @enforce_keys [:text]
  defstruct [:text, provider: %{}]

  @type t() :: %__MODULE__{text: String.t(), provider: map()}
end

defmodule Wardrik.Conversation.ToolCall do
  @moduledoc """
  A call the model asked for: its id, the tool it names, and its arguments,
  decoded. Arguments the model wrote as something other than a JSON object
  are kept as it wrote them, a string, which no tool's schema accepts.
  """

  @enforce_keys [:id, :name, :arguments]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{id: String.t(), name: String.t(), arguments: map() | String.t()}
end

defmodule Wardrik.Conversation.ServerToolCall do
  @moduledoc """
  A call the model's provider ran itself, such as a web search it offers: it
  is already answered, and nothing runs it or answers it here.
  """

  @enforce_keys [:id, :name, :arguments]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{id: String.t(), name: String.t(), arguments: map() | String.t()}
end

defmodule Wardrik.Conversation.Uri do
  @moduledoc "Media at an address, an image or a video, as `modality` says."

  @enforce_keys [:modality, :uri]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{modality: String.t(), uri: String.t()}
end

defmodule Wardrik.Conversation.File do
  @moduledoc "A document a provider holds, by the id it gave it, and its media type where known."

  @enforce_keys [:file_id]
  defstruct [:file_id, :mime_type]

  @type t() :: %__MODULE__{file_id: String.t(), mime_type: String.t() | nil}
end

defmodule Wardrik.Conversation.Blob do
  @moduledoc """
  Media given inline: its bytes, its media type where known, and whether it
  is an `\"image\"` or a `\"document\"`, as `modality`.
  """

  @enforce_keys [:modality, :data]
  defstruct [:modality, :data, :mime_type]

  @type t() :: %__MODULE__{modality: String.t(), data: binary(), mime_type: String.t() | nil}
end
