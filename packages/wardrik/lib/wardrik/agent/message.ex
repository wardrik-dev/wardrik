defmodule Wardrik.Agent.Message do
  @moduledoc """
  A message someone sent an agent, queued for the next turn: its text, the id
  it goes by, who sent it, and what it holds, as `Wardrik.Label`s.

      Wardrik.Agent.Message.new("What changed this week?")
      Wardrik.Agent.Message.new("What changed this week?", "3f6c0a52-…")
      Wardrik.Agent.Message.new(text, nil, sender: maria, labels: ["outside"])

  A caller may choose the id, and an agent takes a message once however many
  times the same id is sent. One the caller leaves out is a new UUIDv7.

  A message's labels are the turn's from its start, and the history's after
  it, as what a tool answers with is: a channel labels a message from someone
  who is not the agent's own `"outside"`, so the agent's hooks weigh it as
  they would a web page.

  ## Who sent it

  `sender` is the `Wardrik.Principal` who sent it, where a surface knows one,
  as a channel does for each person writing in a room. The message's event
  carries it, so the agent's log says who said what, and the model reads it
  ahead of the text, so it can tell several people apart:

      From Maria Chen (channel slack/U024BE7LH):
      Reconcile last week's deposits.

  A message with no sender is read as its text alone.
  """

  alias Wardrik.Principal

  @enforce_keys [:id, :text]
  defstruct [:id, :text, :sender, labels: []]

  @type t() :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          sender: Principal.t() | nil,
          labels: [Wardrik.Label.t()]
        }

  @doc """
  A message with `text`, under `id` or a new one, from `sender:` where
  given, holding what `labels:` names.
  """
  @spec new(String.t(), String.t() | nil,
          sender: Principal.t() | nil,
          labels: [Wardrik.Label.t()]
        ) ::
          t()
  def new(text, id \\ nil, opts \\ []) when is_binary(text) and (is_binary(id) or is_nil(id)) do
    %__MODULE__{
      id: id || Wardrik.UUID.v7(),
      text: text,
      sender: sender!(Keyword.get(opts, :sender)),
      labels: Wardrik.Label.union([], Keyword.get(opts, :labels, []))
    }
  end

  defp sender!(sender) when is_struct(sender, Principal) or is_nil(sender), do: sender

  @doc "What the model reads: the text, after a line naming the sender where there is one."
  @spec content(t()) :: String.t()
  def content(%__MODULE__{sender: nil, text: text}), do: text
  def content(%__MODULE__{sender: sender, text: text}), do: "From #{named(sender)}:\n" <> text

  defp named(sender) do
    known = "#{Principal.type(sender)} #{Principal.id(sender)}"

    case Principal.name(sender) do
      nil -> known
      name -> "#{name} (#{known})"
    end
  end
end
