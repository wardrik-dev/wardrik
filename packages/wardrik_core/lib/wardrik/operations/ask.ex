defmodule Wardrik.Operations.Ask do
  @moduledoc """
  Sends an agent a message from the caller's principal, which it answers in
  a turn of its own: the answer is the `Wardrik.Agent.Message` sent, with
  the `sequence` of the agent's log it was sent at, and the log says the
  rest from there. Where the caller is an agent, made with
  `Wardrik.Caller.agent/1`, the turn that takes the message sends it the
  answer as a message of its own; see "Answering another agent" in
  `Wardrik.Agent`.

  `new/2` reads a message as `WardrikProtocol` describes one: text parts,
  or `content`, with an `id` of the sender's choosing, or one made for it.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Catalog.Entry
  @behaviour Wardrik.Command

  alias Wardrik.Agent
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Error

  @enforce_keys [:agent, :id, :text]
  defstruct [:agent, :id, :text]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), id: String.t(), text: String.t()}

  @impl Wardrik.Catalog.Entry
  def name, do: "agent.ask"

  @impl Wardrik.Catalog.Entry
  def summary,
    do:
      "Send the agent a message, which it answers in a turn of its own. An agent that sends " <>
        "it is sent the answer back, later, as a message from the agent it asked."

  @impl Wardrik.Catalog.Entry
  def input, do: WardrikProtocol.schema("input_agent_ask")

  @impl Wardrik.Catalog.Entry
  def labels(_answer), do: []

  @doc "The request to send the agent `id` `message`, or why it does not read."
  @impl Wardrik.Catalog.Entry
  def new(%Wardrik.AgentID{} = agent, message) do
    with {:ok, id, text} <- text(message),
         do: {:ok, %__MODULE__{agent: agent, id: id, text: text}}
  end

  defp text(%{"parts" => parts} = message) when is_list(parts) do
    texts = for %{"type" => "text", "content" => text} when is_binary(text) <- parts, do: text
    identified(message, Enum.join(texts, "\n"))
  end

  defp text(%{"content" => text} = message) when is_binary(text), do: identified(message, text)
  defp text(_message), do: invalid("A message has text parts, or content")

  defp identified(_message, ""), do: invalid("A message has text to send")
  defp identified(%{"id" => id}, text) when is_binary(id) and id != "", do: {:ok, id, text}
  defp identified(%{"id" => _id}, _text), do: invalid("A message's id is text")
  defp identified(_message, text), do: {:ok, Wardrik.UUID.v7(), text}

  defp invalid(message), do: {:error, Error.new(:invalid, message)}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :message

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: agent, id: id, text: text}} = change, caller) do
    message = Message.new(text, id, sender: caller.principal, reply_to: caller.reply_to)

    with %Snapshot{sequence: sequence} <- Agent.snapshot(agent),
         message = %{message | sequence: sequence},
         :ok <- Agent.queue(agent, message) do
      {:ok, message, change.effect}
    else
      {:error, :not_found} -> {:error, AgentOperation.not_found(agent)}
    end
  end

  @impl Wardrik.Command
  def render(%Message{id: id}), do: %{"message" => %{"id" => id}}

  defimpl Wardrik.Effect do
    def preview(%{agent: agent, id: id, text: text}),
      do: %{"asking" => %{"agent" => to_string(agent), "id" => id, "content" => text}}

    def audit(_ask), do: []
  end
end
