defmodule Wardrik.Operations.Ask do
  @moduledoc """
  Sends an agent a message, which it answers in a turn of its own: the
  answer says the message's ID, and the agent's log says the rest.

  `new/2` reads a message as `wardrik_protocol` describes one: text parts,
  or `content`, with an `id` of the sender's choosing, or one made for it.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Agent
  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Error

  @enforce_keys [:agent, :id, :text]
  defstruct [:agent, :id, :text]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), id: String.t(), text: String.t()}

  @doc "The request to send the agent `id` `message`, or why it does not read."
  @spec new(Wardrik.AgentID.t(), map()) :: {:ok, t()} | {:error, Error.t()}
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
  def make(%Change{request: %__MODULE__{agent: agent, id: id, text: text}}, _caller) do
    case Agent.ask(agent, text, id: id) do
      :ok -> {:ok, %{"message" => %{"id" => id}}}
      {:error, :not_found} -> {:error, AgentOperation.not_found(agent)}
    end
  end
end
