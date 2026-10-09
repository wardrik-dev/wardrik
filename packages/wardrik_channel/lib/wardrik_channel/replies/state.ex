defmodule WardrikChannel.Replies.State do
  @moduledoc """
  What one room's `WardrikChannel.Replies` keeps: each thread it answers in,
  the agent answering there, the last event of that agent's log it has
  posted, and the messages each run under way answers. `retries` counts the
  attempts at each thread's next post, and is not kept.
  """

  alias Wardrik.AgentID

  @enforce_keys [:channel, :room]
  defstruct [:channel, :room, threads: %{}, retries: %{}]

  @typedoc "A thread followed: its agent, how far its log is posted, and its runs under way."
  @type thread() :: %{
          agent: AgentID.t(),
          through: non_neg_integer(),
          runs: %{String.t() => [String.t()]}
        }

  @type t() :: %__MODULE__{
          channel: String.t(),
          room: String.t(),
          threads: %{String.t() => thread()},
          retries: %{String.t() => pos_integer()}
        }

  @typedoc """
  What an event asks to be posted in its thread: what a run answered, and
  the messages it answers; the calls a run waits on; why a run failed; or
  nothing.
  """
  @type post() ::
          {:reply, String.t(), [String.t()]}
          | {:parked, [String.t()]}
          | {:failed, String.t()}
          | :none

  @spec new(String.t(), String.t()) :: t()
  def new(channel, room), do: %__MODULE__{channel: channel, room: room}

  @doc """
  Follows `agent` in `thread`, posting what its log holds after `through`,
  unless the thread is followed already.
  """
  @spec follow(t(), String.t(), AgentID.t(), non_neg_integer()) :: t()
  def follow(%__MODULE__{} = state, thread, %AgentID{} = agent, through) do
    followed = %{agent: agent, through: through, runs: %{}}
    %{state | threads: Map.put_new(state.threads, thread, followed)}
  end

  @doc "Whether `thread` is followed."
  @spec followed?(t(), String.t()) :: boolean()
  def followed?(%__MODULE__{threads: threads}, thread), do: Map.has_key?(threads, thread)

  @doc "The thread whose agent is `agent`, where one is followed."
  @spec thread_of(t(), AgentID.t()) :: String.t() | nil
  def thread_of(%__MODULE__{threads: threads}, %AgentID{} = agent) do
    Enum.find_value(threads, fn {thread, followed} -> if followed.agent == agent, do: thread end)
  end

  @doc """
  What `event`, the next in `thread`'s log, asks to be posted, and the state
  once it has been.
  """
  @spec take(t(), String.t(), map()) :: {post(), t()}
  def take(%__MODULE__{} = state, thread, %{"sequence" => sequence} = event) do
    followed = Map.fetch!(state.threads, thread)
    {post, runs} = post(event, followed.runs)
    followed = %{followed | through: String.to_integer(sequence), runs: runs}
    {post, %{state | threads: Map.put(state.threads, thread, followed)}}
  end

  @doc "Moves `thread` past what its log no longer holds, to just before `oldest`."
  @spec skip(t(), String.t(), pos_integer()) :: t()
  def skip(%__MODULE__{} = state, thread, oldest) do
    followed = Map.fetch!(state.threads, thread)
    followed = %{followed | through: max(followed.through, oldest - 1)}
    %{state | threads: Map.put(state.threads, thread, followed)}
  end

  defp post(%{"type" => "wardrik.run.started", "data" => %{"run" => run}}, runs),
    do: {:none, Map.put(runs, run["id"], Map.get(run, "message_ids", []))}

  defp post(%{"type" => "wardrik.run.completed", "data" => data}, runs) do
    {answering, runs} = Map.pop(runs, data["run"]["id"], [])
    {{:reply, last_said(data["messages"]), answering}, runs}
  end

  defp post(%{"type" => "wardrik.run.interrupted", "data" => data}, runs),
    do: {{:parked, Enum.map(data["interrupts"], & &1["id"])}, runs}

  defp post(%{"type" => "wardrik.run.failed", "data" => data}, runs),
    do: {{:failed, data["error"]["message"]}, Map.delete(runs, data["run"]["id"])}

  defp post(%{"type" => "wardrik.run.cancelled", "data" => data}, runs),
    do: {:none, Map.delete(runs, data["run"]["id"])}

  defp post(_event, runs), do: {:none, runs}

  defp last_said(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{"role" => "assistant", "parts" => parts} -> presence(text(parts))
      _message -> nil
    end)
  end

  defp text(parts),
    do: for(%{"type" => "text", "content" => text} <- parts, into: "", do: text)

  defp presence(""), do: nil
  defp presence(text), do: text
end
