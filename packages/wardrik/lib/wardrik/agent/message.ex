defmodule Wardrik.Agent.Message do
  @moduledoc """
  A message someone sent an agent, queued for the next turn: its text, the id
  it goes by, and what it holds, as `Wardrik.Label`s.

      Wardrik.Agent.Message.new("What changed this week?")
      Wardrik.Agent.Message.new("What changed this week?", "3f6c0a52-…")
      Wardrik.Agent.Message.new(text, nil, labels: ["outside"])

  A caller may choose the id, and an agent takes a message once however many
  times the same id is sent. One the caller leaves out is a new UUIDv7.

  A message's labels are the turn's from its start, and the history's after
  it, as what a tool answers with is: a channel labels a message from someone
  who is not the agent's own `"outside"`, so the agent's hooks weigh it as
  they would a web page.
  """

  @enforce_keys [:id, :text]
  defstruct [:id, :text, labels: []]

  @type t() :: %__MODULE__{id: String.t(), text: String.t(), labels: [Wardrik.Label.t()]}

  @doc "A message with `text`, under `id` or a new one, holding what `labels:` names."
  @spec new(String.t(), String.t() | nil, labels: [Wardrik.Label.t()]) :: t()
  def new(text, id \\ nil, opts \\ []) when is_binary(text) and (is_binary(id) or is_nil(id)) do
    %__MODULE__{
      id: id || Wardrik.UUID.v7(),
      text: text,
      labels: Wardrik.Label.union([], Keyword.get(opts, :labels, []))
    }
  end
end
