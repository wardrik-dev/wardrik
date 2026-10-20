defmodule Wardrik.Wait do
  @moduledoc false
  # Follows an agent's log from a cursor to the end of one run, for
  # `Wardrik.agent_await/3`.

  alias Wardrik.AgentAddress
  alias Wardrik.Error
  alias Wardrik.Event.Cursor
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Reply
  alias Wardrik.Waiting

  @ends ~w(wardrik.run.completed wardrik.run.interrupted wardrik.run.failed wardrik.run.cancelled)
  @types ["wardrik.run.started", "wardrik.run.resumed" | @ends]

  @reasons %{
    "tool_approval" => :tool_approval,
    "model_approval" => :model_approval,
    "authorization" => :authorization,
    "in_doubt" => :in_doubt
  }

  @type awaited() :: {:asked, String.t()} | {:resumed, String.t()}
  @type answer() :: {:ok, Reply.t()} | {:waiting, Waiting.t()} | {:error, Error.t()}

  @spec answer(WardrikStore.t(), AgentAddress.t(), String.t(), awaited(), timeout()) :: answer()
  def answer(store, agent, cursor, awaited, ms) do
    task = Task.async(fn -> follow(store, agent, cursor, awaited) end)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, answer} ->
        answer

      nil ->
        {:error, Error.new(:timeout, "#{agent} had not finished after #{ms} ms. It carries on.")}
    end
  end

  defp follow(store, agent, cursor, awaited) do
    {:ok, positions} = Cursor.decode(cursor)

    store
    |> Log.stream([AgentAddress.resource(agent)], after: positions, follow: true, types: @types)
    |> Enum.reduce_while(awaited, &step(&1, &2, agent, cursor))
  end

  defp step(
         %Entry{event: %{"type" => "wardrik.run.started"} = event},
         {:asked, id},
         _agent,
         _cursor
       ) do
    %{"data" => %{"run" => %{"id" => run} = about}} = event

    if id in Map.get(about, "message_ids", []),
      do: {:cont, {:run, run}},
      else: {:cont, {:asked, id}}
  end

  defp step(
         %Entry{event: %{"type" => "wardrik.run.resumed", "data" => %{"run" => %{"id" => run}}}},
         {:resumed, run},
         _agent,
         _cursor
       ),
       do: {:cont, {:run, run}}

  defp step(
         %Entry{event: %{"type" => type, "data" => %{"run" => %{"id" => run}} = data}} = entry,
         {:run, run},
         agent,
         cursor
       )
       when type in @ends,
       do: {:halt, ended(type, data, agent, run, Cursor.past(cursor, entry))}

  # Another run's, or a log trimmed past the cursor, which holds no run.
  defp step(%Entry{}, awaited, _agent, _cursor), do: {:cont, awaited}

  defp ended("wardrik.run.completed", %{"messages" => messages}, agent, run, cursor),
    do:
      {:ok,
       %Reply{agent: agent, run: run, text: text(messages), messages: messages, cursor: cursor}}

  defp ended("wardrik.run.interrupted", %{"interrupts" => interrupts}, agent, run, cursor),
    do:
      {:waiting,
       %Waiting{agent: agent, run: run, calls: Enum.map(interrupts, &call/1), cursor: cursor}}

  defp ended("wardrik.run.failed", %{"error" => error}, agent, _run, _cursor),
    do:
      {:error,
       Error.new(:failed, "#{agent}'s run failed: #{error["message"]}", %{"error" => error})}

  defp ended("wardrik.run.cancelled", %{"resolution" => resolution}, agent, _run, _cursor),
    do:
      {:error,
       Error.new(:cancelled, "#{agent}'s run was stopped.", %{"resolution" => resolution})}

  defp text(messages) do
    for(
      %{"role" => "assistant", "parts" => parts} <- messages,
      %{"type" => "text", "content" => content} <- parts,
      do: content
    )
    |> Enum.join("\n\n")
  end

  defp call(%{"id" => id, "reason" => reason, "message" => message} = interrupt),
    do: %{id: id, reason: Map.fetch!(@reasons, reason), message: message, name: interrupt["name"]}
end
