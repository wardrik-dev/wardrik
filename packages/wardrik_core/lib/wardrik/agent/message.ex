defmodule Wardrik.Agent.Message do
  @moduledoc """
  A message someone sent an agent, queued for the next turn: its text, the id
  it goes by, who sent it, what it holds, as `Wardrik.Label`s, and the agents
  its answer goes to.

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

      From Maria Chen (slack:T0123/U024BE7LH):
      Reconcile last week's deposits.

  A message with no sender is read as its text alone.

  ## Where its answer goes

  `reply_to` lists the agents the answer goes to, besides the agent's log:
  the agent that asked, for a message one agent sends another. The turn that
  takes the message sends each of them its answer as a message of its own;
  see "Answering another agent" in `Wardrik.Agent`. Most messages list none,
  and are answered in the log alone.

  ## Where its turn is in the log

  `agent` is the agent it was sent to, and `cursor` where that agent's log
  stood as it was sent, where its sender read it first, as
  `Wardrik.agent_ask/4` does, and `nil` otherwise. The turn that answers it
  is written after it, so `Wardrik.agent_await/3` waits for that turn, and
  a client reads the log on from there with `Wardrik.events/2`.
  """

  alias Wardrik.Principal

  @enforce_keys [:id, :text]
  defstruct [:id, :text, :sender, :agent, :cursor, labels: [], reply_to: []]

  @type t() :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          sender: Principal.t() | nil,
          labels: [Wardrik.Label.t()],
          reply_to: [Wardrik.AgentAddress.t()],
          agent: Wardrik.AgentAddress.t() | nil,
          cursor: String.t() | nil
        }

  @doc """
  A message with `text`, under `id` or a new one, from `sender:` where
  given, holding what `labels:` names, answered to the agents `reply_to:`
  lists as well as in the log.
  """
  @spec new(String.t(), String.t() | nil,
          sender: Principal.t() | nil,
          labels: [Wardrik.Label.t()],
          reply_to: [Wardrik.AgentAddress.t()]
        ) ::
          t()
  def new(text, id \\ nil, opts \\ []) when is_binary(text) and (is_binary(id) or is_nil(id)) do
    %__MODULE__{
      id: id || Wardrik.UUID.v7(),
      text: text,
      sender: sender!(Keyword.get(opts, :sender)),
      labels: Wardrik.Label.union([], Keyword.get(opts, :labels, [])),
      reply_to: Keyword.get(opts, :reply_to, [])
    }
  end

  defp sender!(sender) when is_struct(sender, Principal) or is_nil(sender), do: sender

  @doc """
  The text and id of `message`, as `WardrikProtocol` describes one: its
  text parts joined, or its `content`, and the `id` of the sender's
  choosing, `nil` where it gives none; or why it does not read.

      Wardrik.Agent.Message.read(%{"content" => "Where is order 1001?", "id" => "m1"})
      #=> {:ok, "Where is order 1001?", "m1"}
  """
  @spec read(map()) :: {:ok, String.t(), String.t() | nil} | {:error, Wardrik.Error.t()}
  def read(%{"parts" => parts} = message) when is_list(parts) do
    texts = for %{"type" => "text", "content" => text} when is_binary(text) <- parts, do: text
    identified(message, Enum.join(texts, "\n"))
  end

  def read(%{"content" => text} = message) when is_binary(text), do: identified(message, text)
  def read(_message), do: invalid("A message has text parts, or content")

  defp identified(%{"id" => id}, text) when is_binary(id), do: {:ok, text, id}
  defp identified(%{"id" => _id}, _text), do: invalid("A message's id is text")
  defp identified(_message, text), do: {:ok, text, nil}

  defp invalid(message), do: {:error, Wardrik.Error.new(:invalid, message)}

  @doc "What the model reads: the text, after a line naming the sender where there is one."
  @spec content(t()) :: String.t()
  def content(%__MODULE__{sender: nil, text: text}), do: text
  def content(%__MODULE__{sender: sender, text: text}), do: "From #{named(sender)}:\n" <> text

  defp named(sender) do
    case Principal.name(sender) do
      nil -> Principal.id(sender)
      name -> "#{name} (#{Principal.id(sender)})"
    end
  end
end
