defmodule Wardrik.LLM.Answer do
  @moduledoc """
  What a model answered one call with: the assistant message it said, what
  it used, as `Wardrik.LLM.Usage`, why it stopped, the model that answered
  and the id its provider gave the answer. An evaluation's answers are its
  `object`, with string keys; see `Wardrik.LLM.Client.evaluate/3`.

  `usage` is `nil` where the provider said nothing of what the call used.
  `finish_reason` is `:stop`, `:length`, `:tool_calls`, `:content_filter`,
  `:error`, `:cancelled`, `:incomplete` or `:unknown`, or `nil` where the
  provider gave none.
  """

  alias Wardrik.Conversation.Assistant
  alias Wardrik.LLM.Usage

  @enforce_keys [:message]
  defstruct [:message, :usage, :finish_reason, :model, :id, :object]

  @type finish_reason() ::
          :stop
          | :length
          | :tool_calls
          | :content_filter
          | :error
          | :cancelled
          | :incomplete
          | :unknown

  @type t() :: %__MODULE__{
          message: Assistant.t(),
          usage: Usage.t() | nil,
          finish_reason: finish_reason() | nil,
          model: String.t() | nil,
          id: String.t() | nil,
          object: map() | nil
        }
end
