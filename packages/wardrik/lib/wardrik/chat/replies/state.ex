defmodule Wardrik.Chat.Replies.State do
  @moduledoc false

  @kept [:workspace, :room, :conversations, :cursor, :senders, :runs]

  @enforce_keys [:workspace, :room]
  defstruct [
    :workspace,
    :room,
    :cursor,
    :channel,
    :follower,
    conversations: [],
    senders: %{},
    runs: %{},
    shown: %{}
  ]

  @type run() :: %{id: String.t(), answering: [String.t()], asked_by: String.t() | nil}

  @typedoc "A conversation, as the agent's ID and the conversation's."
  @type conversation() :: {agent :: String.t(), conversation :: String.t() | nil}

  @type t() :: %__MODULE__{
          workspace: String.t(),
          room: String.t(),
          cursor: String.t() | nil,
          channel: Wardrik.Chat.Channel.t() | nil,
          follower: pid() | nil,
          conversations: [conversation()],
          senders: %{String.t() => String.t()},
          runs: %{conversation() => run()},
          shown: %{conversation() => integer()}
        }

  @typedoc """
  What an event asks to post in its thread. `:none` posts nothing. The rest match
  `t:Wardrik.Chat.Outbound.body/0`, except `{:waiting, interrupt_ids, asked_by}`.
  """
  @type post() ::
          {:reply, String.t(), [String.t()]}
          | {:status, String.t()}
          | {:waiting, [String.t()], String.t() | nil}
          | {:failed, String.t()}
          | {:stopped, [String.t()]}
          | {:said, String.t()}
          | :none

  @doc "Returns the state of a room no one has posted in yet."
  @spec new(String.t(), String.t()) :: t()
  def new(workspace, room), do: %__MODULE__{workspace: workspace, room: room}

  @doc "Returns the part of `state` saved between restarts."
  @spec dump(t()) :: map()
  def dump(state), do: Map.take(state, @kept)

  @doc "Restores the state from `dump/1`'s result."
  @spec load(map()) :: t()
  def load(dumped), do: struct!(__MODULE__, dumped)

  @doc "Returns what `event` of `conversation` asks to post, and the updated state."
  @spec take(t(), conversation(), Wardrik.Event.t()) :: {post(), t()}
  def take(state, conversation, %Wardrik.Event{type: "wardrik." <> type, data: data}),
    do: taken(state, conversation, type, data)

  @doc "Returns who asked for the run under way in `conversation`, or `nil` if unknown."
  @spec asked_by(t(), conversation()) :: String.t() | nil
  def asked_by(state, conversation), do: get_in(state.runs, [conversation, :asked_by])

  defp taken(state, _conversation, "message.created", %{
         "message" => %{"id" => id},
         "sender" => %{"id" => sender}
       }),
       do: {:none, put_in(state.senders[id], sender)}

  defp taken(state, conversation, "run.started", %{"run" => run}) do
    answering = Map.get(run, "message_ids", [])
    {asked, senders} = Map.split(state.senders, answering)
    run = %{id: run["id"], answering: answering, asked_by: first_sender(asked, answering)}
    state = %{state | senders: senders, runs: Map.put(state.runs, conversation, run)}
    {{:status, "is thinking…"}, state}
  end

  defp taken(state, _conversation, "tool_call.started", %{"tool" => %{"name" => name}}),
    do: {{:status, "is running #{name}…"}, state}

  defp taken(state, conversation, "run.completed", %{"messages" => messages}),
    do:
      {{:reply, last_said(messages), answering(state, conversation)}, ended(state, conversation)}

  defp taken(state, conversation, "run.interrupted", %{"interrupts" => interrupts}),
    do: {{:waiting, Enum.map(interrupts, & &1["id"]), asked_by(state, conversation)}, state}

  defp taken(state, conversation, "run.failed", %{"error" => error}),
    do: {{:failed, error["message"]}, ended(state, conversation)}

  defp taken(state, conversation, "run.cancelled", _data),
    do: {{:stopped, answering(state, conversation)}, ended(state, conversation)}

  defp taken(state, _conversation, "interrupt.resolved", data),
    do:
      {{:said,
        decided(data["decision"], decider(data["resolved_by"]), data["note"] || data["reason"])},
       state}

  defp taken(state, _conversation, _type, _data), do: {:none, state}

  defp first_sender(asked, [first | _rest]), do: Map.get(asked, first)
  defp first_sender(_asked, []), do: nil

  defp answering(state, conversation), do: get_in(state.runs, [conversation, :answering]) || []

  defp ended(state, conversation), do: %{state | runs: Map.delete(state.runs, conversation)}

  defp decider(%{"name" => name}) when is_binary(name), do: name
  defp decider(%{"id" => id}), do: id
  defp decider(nil), do: "someone"

  defp decided("approved", name, nil), do: "Approved by #{name}."
  defp decided("approved", name, note), do: "Approved by #{name}: #{note}"
  defp decided(_rejected, name, nil), do: "Denied by #{name}."
  defp decided(_rejected, name, reason), do: "Denied by #{name}: #{reason}"

  defp last_said(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", &said/1)
  end

  defp said(%{"role" => "assistant", "parts" => parts}) do
    case text(parts) do
      "" -> nil
      text -> text
    end
  end

  defp said(_message), do: nil

  defp text(parts), do: Enum.map_join(parts, &part_text/1)

  defp part_text(%{"type" => "text", "content" => text}), do: text
  defp part_text(_part), do: ""
end
