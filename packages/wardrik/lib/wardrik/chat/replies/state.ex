defmodule Wardrik.Chat.Replies.State do
  @moduledoc false

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

  @doc "Returns the part of `state` saved between restarts, as JSON."
  @spec dump(t()) :: map()
  def dump(state) do
    %{
      "workspace" => state.workspace,
      "room" => state.room,
      "cursor" => state.cursor,
      "conversations" => Enum.map(state.conversations, &Tuple.to_list/1),
      "senders" => state.senders,
      "runs" =>
        for {{agent, conversation}, run} <- state.runs do
          %{
            "agent" => agent,
            "conversation" => conversation,
            "id" => run.id,
            "answering" => run.answering,
            "asked_by" => run.asked_by
          }
        end
    }
  end

  @doc "Restores the state from `dump/1`'s result."
  @spec load(map()) :: t()
  def load(dumped) do
    %__MODULE__{
      workspace: dumped["workspace"],
      room: dumped["room"],
      cursor: dumped["cursor"],
      conversations: Enum.map(dumped["conversations"], &List.to_tuple/1),
      senders: dumped["senders"],
      runs:
        Map.new(dumped["runs"], fn run ->
          {{run["agent"], run["conversation"]},
           %{id: run["id"], answering: run["answering"], asked_by: run["asked_by"]}}
        end)
    }
  end

  @doc "Returns what `event` of `conversation` asks to post, and the updated state."
  @spec take(t(), conversation(), Wardrik.Event.t()) :: {post(), t()}
  def take(state, conversation, %Wardrik.Event{type: "wardrik." <> type, data: data}),
    do: handle_take(state, conversation, type, data)

  @doc "Returns who asked for the run under way in `conversation`, or `nil` if unknown."
  @spec find_asker(t(), conversation()) :: String.t() | nil
  def find_asker(state, conversation), do: get_in(state.runs, [conversation, :asked_by])

  defp handle_take(state, _conversation, "message.created", %{
         "message" => %{"id" => id},
         "sender" => %{"id" => sender}
       }),
       do: {:none, put_in(state.senders[id], sender)}

  defp handle_take(state, conversation, "run.started", %{"run" => run}) do
    answering = Map.get(run, "message_ids", [])
    {asked, senders} = Map.split(state.senders, answering)
    run = %{id: run["id"], answering: answering, asked_by: first_sender(asked, answering)}
    state = %{state | senders: senders, runs: Map.put(state.runs, conversation, run)}
    {{:status, "is thinking…"}, state}
  end

  defp handle_take(state, _conversation, "tool_call.started", %{"tool" => %{"name" => name}}),
    do: {{:status, "is running #{name}…"}, state}

  defp handle_take(state, conversation, "run.completed", %{"messages" => messages}),
    do:
      {{:reply, last_said(messages), answering(state, conversation)}, finish(state, conversation)}

  defp handle_take(state, conversation, "run.interrupted", %{"interrupts" => interrupts}),
    do: {{:waiting, Enum.map(interrupts, & &1["id"]), find_asker(state, conversation)}, state}

  defp handle_take(state, conversation, "run.failed", %{"error" => error}),
    do: {{:failed, error["message"]}, finish(state, conversation)}

  defp handle_take(state, conversation, "run.cancelled", _data),
    do: {{:stopped, answering(state, conversation)}, finish(state, conversation)}

  defp handle_take(state, _conversation, "interrupt.resolved", data),
    do:
      {{:said,
        decide(data["decision"], decider(data["resolved_by"]), data["note"] || data["reason"])},
       state}

  defp handle_take(state, _conversation, _type, _data), do: {:none, state}

  defp first_sender(asked, [first | _rest]), do: Map.get(asked, first)
  defp first_sender(_asked, []), do: nil

  defp answering(state, conversation), do: get_in(state.runs, [conversation, :answering]) || []

  defp finish(state, conversation), do: %{state | runs: Map.delete(state.runs, conversation)}

  defp decider(%{"name" => name}) when is_binary(name), do: name
  defp decider(%{"id" => id}), do: id
  defp decider(nil), do: "someone"

  defp decide("approved", name, nil), do: "Approved by #{name}."
  defp decide("approved", name, note), do: "Approved by #{name}: #{note}"
  defp decide(_rejected, name, nil), do: "Denied by #{name}."
  defp decide(_rejected, name, reason), do: "Denied by #{name}: #{reason}"

  defp last_said(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", &say/1)
  end

  defp say(%{"role" => "assistant", "parts" => parts}) do
    case text(parts) do
      "" -> nil
      text -> text
    end
  end

  defp say(_message), do: nil

  defp text(parts), do: Enum.map_join(parts, &part_text/1)

  defp part_text(%{"type" => "text", "content" => text}), do: text
  defp part_text(_part), do: ""
end
