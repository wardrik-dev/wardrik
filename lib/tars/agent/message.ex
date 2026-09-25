defmodule Tars.Agent.Message do
  @moduledoc """
  A message someone sent an agent, queued for the next turn: its text, and the
  id it goes by.

      Tars.Agent.Message.new("What changed this week?")
      Tars.Agent.Message.new("What changed this week?", "3f6c0a52-…")

  A caller may choose the id, and an agent takes a message once however many
  times the same id is sent. One the caller leaves out is a new UUIDv7.
  """

  @enforce_keys [:id, :text]
  defstruct [:id, :text]

  @type t() :: %__MODULE__{id: String.t(), text: String.t()}

  @doc "A message with `text`, under `id` or a new one."
  @spec new(String.t(), String.t() | nil) :: t()
  def new(text, id \\ nil) when is_binary(text) and (is_binary(id) or is_nil(id)),
    do: %__MODULE__{id: id || Tars.UUID.v7(), text: text}
end
