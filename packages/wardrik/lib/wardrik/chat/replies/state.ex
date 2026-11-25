defmodule Wardrik.Chat.Replies.State do
  @moduledoc false

  alias Wardrik.Chat.Step

  @enforce_keys [:workspace, :room]
  defstruct [
    :workspace,
    :room,
    :cursor,
    :channel,
    :follower,
    conversations: [],
    senders: %{},
    askers: %{},
    runs: %{},
    shown: %{},
    beats: %{}
  ]

  @reasoning_tail 300
  @steps 45

  @type run() :: %{
          id: String.t(),
          answering: [String.t()],
          asked_by: String.t() | nil,
          asker: String.t() | nil,
          progress: String.t() | nil,
          steps: [Step.t()]
        }

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
          askers: %{String.t() => String.t()},
          runs: %{conversation() => run()},
          shown: %{conversation() => integer()},
          beats: %{conversation() => reference()}
        }

  @typedoc """
  What an event asks to post in its thread. `:none` posts nothing. `{:progress, :changed}` posts
  the run's steps, and `{:progress, :details}` too unless it posted them a moment ago. The rest
  match `t:Wardrik.Chat.Outbound.body/0`, except `{:waiting, interrupt_ids, asked_by}`.
  """
  @type post() ::
          {:progress, :changed | :details}
          | {:reply, String.t(), [String.t()]}
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
      "askers" => state.askers,
      "runs" =>
        for {{agent, conversation}, run} <- state.runs do
          %{
            "agent" => agent,
            "conversation" => conversation,
            "id" => run.id,
            "answering" => run.answering,
            "asked_by" => run.asked_by,
            "asker" => run.asker,
            "progress" => run.progress,
            "steps" => Enum.map(run.steps, &dump_step/1)
          }
        end
    }
  end

  @doc """
  Restores the state from `dump/1`'s result, as version `vsn` saved it.

  Version 2 kept no askers and no progress.
  """
  @spec load(pos_integer(), map()) :: t()
  def load(2, dumped) do
    runs =
      Enum.map(
        dumped["runs"],
        &Map.merge(&1, %{"asker" => nil, "progress" => nil, "steps" => []})
      )

    upgraded = Map.merge(dumped, %{"runs" => runs, "askers" => %{}})
    load(3, upgraded)
  end

  def load(3, dumped) do
    %__MODULE__{
      workspace: dumped["workspace"],
      room: dumped["room"],
      cursor: dumped["cursor"],
      conversations: Enum.map(dumped["conversations"], &List.to_tuple/1),
      senders: dumped["senders"],
      askers: dumped["askers"],
      runs:
        Map.new(dumped["runs"], fn run ->
          {{run["agent"], run["conversation"]},
           %{
             id: run["id"],
             answering: run["answering"],
             asked_by: run["asked_by"],
             asker: run["asker"],
             progress: run["progress"],
             steps: Enum.map(run["steps"], &load_step/1)
           }}
        end)
    }
  end

  defp dump_step(step) do
    %{
      "id" => step.id,
      "title" => step.title,
      "status" => Atom.to_string(step.status),
      "details" => step.details,
      "since" => DateTime.to_iso8601(step.since)
    }
  end

  defp load_step(dumped) do
    {:ok, since, _offset} = DateTime.from_iso8601(dumped["since"])

    %Step{
      id: dumped["id"],
      title: dumped["title"],
      status: load_status(dumped["status"]),
      details: dumped["details"],
      since: since
    }
  end

  defp load_status("running"), do: :running
  defp load_status("waiting"), do: :waiting
  defp load_status("done"), do: :done
  defp load_status("failed"), do: :failed

  @doc "Notes that the chat member `asker` sent the message `id`, for the run that answers it."
  @spec put_asker(t(), String.t(), String.t()) :: t()
  def put_asker(state, id, asker), do: put_in(state.askers[id], asker)

  @doc "Returns what `event` of `conversation` asks to post, and the updated state."
  @spec take(t(), conversation(), Wardrik.Event.t()) :: {post(), t()}
  def take(state, conversation, %Wardrik.Event{type: "wardrik." <> type} = event),
    do: handle_take(state, conversation, type, event)

  @doc "Returns who asked for the run under way in `conversation`, or `nil` if unknown."
  @spec find_asker(t(), conversation()) :: String.t() | nil
  def find_asker(state, conversation), do: get_in(state.runs, [conversation, :asked_by])

  @doc "Returns the run under way in `conversation`, or `nil`."
  @spec find_run(t(), conversation()) :: run() | nil
  def find_run(state, conversation), do: Map.get(state.runs, conversation)

  @doc "Notes the ID the adapter returned for the progress of `conversation`'s run."
  @spec put_progress(t(), conversation(), String.t()) :: t()
  def put_progress(state, conversation, progress) do
    if Map.has_key?(state.runs, conversation),
      do: put_in(state.runs[conversation].progress, progress),
      else: state
  end

  @doc "Returns whether a step of `conversation`'s run is running."
  @spec running?(t(), conversation()) :: boolean()
  def running?(state, conversation) do
    case find_run(state, conversation) do
      %{steps: steps} -> Enum.any?(steps, &(&1.status == :running))
      nil -> false
    end
  end

  defp handle_take(state, _conversation, "message.created", %{data: data}),
    do: {:none, note_sender(state, data)}

  defp handle_take(state, conversation, "run.started", %{data: %{"run" => run}}) do
    answering = Map.get(run, "message_ids", [])
    {asked, senders} = Map.split(state.senders, answering)
    {askers, rest} = Map.split(state.askers, answering)

    run = %{
      id: run["id"],
      answering: answering,
      asked_by: first_found(asked, answering),
      asker: first_found(askers, answering),
      progress: nil,
      steps: []
    }

    {:none,
     %{state | senders: senders, askers: rest, runs: Map.put(state.runs, conversation, run)}}
  end

  defp handle_take(state, conversation, "message.started", %{data: data} = event),
    do: start_step(state, conversation, data["message"]["id"], "Thinking", event)

  defp handle_take(state, conversation, "reasoning.delta", %{data: data}) do
    if state.channel.reasoning,
      do: add_reasoning(state, conversation, data["message"]["id"], data["delta"]),
      else: {:none, state}
  end

  defp handle_take(state, conversation, "message.delta", %{data: data}) do
    id = data["message"]["id"]

    case find_step(state, conversation, id) do
      %Step{title: "Thinking"} -> change_step(state, conversation, id, &%{&1 | title: "Writing"})
      _other -> {:none, state}
    end
  end

  defp handle_take(state, conversation, "message.retrying", %{data: data}),
    do: note_retry(state, conversation, data["message"]["id"], "The model", data)

  defp handle_take(state, conversation, "message.completed", %{data: data}),
    do: end_step(state, conversation, data["message"]["id"], data)

  defp handle_take(state, conversation, "tool_call.started", %{data: %{"tool" => tool}} = event),
    do: start_step(state, conversation, tool["call"]["id"], "Running #{tool["name"]}", event)

  defp handle_take(state, conversation, "tool_call.retrying", %{data: %{"tool" => tool} = data}),
    do: note_retry(state, conversation, tool["call"]["id"], tool["name"], data)

  defp handle_take(state, conversation, "tool_call.completed", %{data: %{"tool" => tool} = data}),
    do: end_step(state, conversation, tool["call"]["id"], data)

  defp handle_take(state, conversation, "subagent.started", %{data: data} = event),
    do:
      start_step(
        state,
        conversation,
        subagent_step_id(data),
        "Asked #{data["agent"]["name"]}",
        event
      )

  defp handle_take(state, conversation, "subagent.progress", %{data: data}) do
    calls = data["tool_calls"]
    said = "Running #{data["tool"]["name"]}, #{calls} #{if calls == 1, do: "call", else: "calls"}"
    change_step(state, conversation, subagent_step_id(data), &%{&1 | details: said})
  end

  defp handle_take(state, conversation, "subagent.completed", %{data: data}),
    do:
      change_step(
        state,
        conversation,
        subagent_step_id(data),
        &%{&1 | status: :done, details: nil}
      )

  defp handle_take(state, conversation, "subagent.failed", %{data: data}),
    do: end_step(state, conversation, subagent_step_id(data), Map.put(data, "status", "error"))

  defp handle_take(state, conversation, "run.completed", %{data: %{"messages" => messages}}),
    do:
      {{:reply, last_said(messages), answering(state, conversation)}, finish(state, conversation)}

  defp handle_take(state, conversation, "run.interrupted", %{data: %{"interrupts" => interrupts}}),
       do:
         {{:waiting, Enum.map(interrupts, & &1["id"]), find_asker(state, conversation)},
          restart(state, conversation)}

  defp handle_take(state, conversation, "run.resumed", _event),
    do: {:none, restart(state, conversation)}

  defp handle_take(state, conversation, "run.failed", %{data: %{"error" => error}}),
    do: {{:failed, error["message"]}, finish(state, conversation)}

  defp handle_take(state, conversation, "run.deadline_exceeded", _event),
    do: {{:failed, "It ran out of time."}, finish(state, conversation)}

  defp handle_take(state, conversation, "run.cancelled", _event),
    do: {{:stopped, answering(state, conversation)}, finish(state, conversation)}

  defp handle_take(state, _conversation, "interrupt.resolved", %{data: data}),
    do:
      {{:said,
        decide(data["decision"], decider(data["resolved_by"]), data["note"] || data["reason"])},
       state}

  defp handle_take(state, _conversation, _type, _event), do: {:none, state}

  defp note_sender(state, %{"message" => %{"id" => id}, "sender" => %{"id" => sender}}),
    do: put_in(state.senders[id], sender)

  defp note_sender(state, _data), do: state

  defp first_found(found, [first | _rest]), do: Map.get(found, first)
  defp first_found(_found, []), do: nil

  # The events name a subagent alone, so one asked twice at once shares a step.
  defp subagent_step_id(data), do: "subagent-" <> data["agent"]["name"]

  defp start_step(state, conversation, id, title, %Wardrik.Event{time: time}) do
    step = %Step{id: id, title: title, status: :running, since: time}

    update_steps(state, conversation, fn steps ->
      steps
      |> Enum.reject(&(&1.id == id))
      |> Kernel.++([step])
      |> Enum.take(-@steps)
    end)
  end

  defp add_reasoning(state, conversation, id, delta) do
    case find_step(state, conversation, id) do
      %Step{status: :running, details: details} ->
        tail = reasoning_tail(details, delta)
        {_post, state} = change_step(state, conversation, id, &%{&1 | details: tail})
        {{:progress, :details}, state}

      _other ->
        {:none, state}
    end
  end

  defp reasoning_tail(nil, delta), do: reasoning_tail("", delta)

  defp reasoning_tail(details, delta) do
    joined = details <> delta
    String.slice(joined, -@reasoning_tail, @reasoning_tail)
  end

  defp note_retry(state, conversation, id, what, data) do
    said =
      "#{what} failed: #{data["error"]["message"]}. Trying again in " <>
        "#{div(data["wait_ms"] + 999, 1000)}s (attempt #{data["attempt"]} of #{data["attempts"]})."

    change_step(state, conversation, id, &%{&1 | details: said})
  end

  defp end_step(state, conversation, id, %{"status" => "error", "error" => error}),
    do: change_step(state, conversation, id, &%{&1 | status: :failed, details: error["message"]})

  defp end_step(state, conversation, id, _ok),
    do: change_step(state, conversation, id, &%{&1 | status: :done, details: nil})

  defp find_step(state, conversation, id) do
    case find_run(state, conversation) do
      %{steps: steps} -> Enum.find(steps, &(&1.id == id))
      nil -> nil
    end
  end

  defp change_step(state, conversation, id, change) do
    if find_step(state, conversation, id),
      do:
        update_steps(
          state,
          conversation,
          &Enum.map(&1, fn step -> change_one(step, id, change) end)
        ),
      else: {:none, state}
  end

  defp change_one(%Step{id: id} = step, id, change), do: change.(step)
  defp change_one(step, _id, _change), do: step

  defp update_steps(state, conversation, update) do
    if Map.has_key?(state.runs, conversation),
      do: {{:progress, :changed}, update_in(state.runs[conversation].steps, update)},
      else: {:none, state}
  end

  defp restart(state, conversation) do
    if Map.has_key?(state.runs, conversation),
      do: update_in(state.runs[conversation], &%{&1 | progress: nil, steps: []}),
      else: state
  end

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
