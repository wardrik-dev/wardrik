defmodule WardrikChannel.Replies.State do
  @moduledoc """
  What one room's `WardrikChannel.Replies` keeps: each thread it answers in,
  the agent answering there, the cursor past what of that agent's log it
  has posted, and the messages each run under way answers. `retries` holds
  each thread's post being tried again, with its attempts, `posting` is
  the `WardrikChannel.Channel` it posts through, `showing` how it shows
  what each thread's agent is doing, as `WardrikChannel.Replies` takes it,
  `statuses` where each thread's status stands, and `followers` the
  supervisor its threads' followers run under; none of them is kept.
  """

  alias Wardrik.Thread

  @enforce_keys [:channel, :workspace, :room]
  defstruct [
    :channel,
    :workspace,
    :room,
    :posting,
    :showing,
    :followers,
    threads: %{},
    retries: %{},
    statuses: %{}
  ]

  @typedoc "A thread followed: its agent, the cursor past what is posted, and its runs under way."
  @type thread() :: %{
          agent: Thread.t(),
          cursor: String.t(),
          runs: %{String.t() => [String.t()]}
        }

  @typedoc """
  A post being tried again: the attempts made, the event and the cursor
  past it, and the follower waiting on it.
  """
  @type retry() :: {pos_integer(), {map(), String.t(), GenServer.from()}}

  @typedoc """
  How it shows what each thread's agent is doing: the presenter that words
  it, the least time between two statuses, and how long one stands
  unchanged before it is shown again, in milliseconds.
  """
  @type showing() :: %{
          presenter: Wardrik.Agent.Activity.Presenter.t(),
          throttle: pos_integer(),
          refresh: pos_integer()
        }

  @typedoc """
  Where a thread's status stands, under the tag of the timer that ends it,
  with the words it shows, `nil` once a post has taken them away: `:shown`
  until it may change, `:changed` where what the agent is doing has changed
  since, and `:standing` until it is shown again.
  """
  @type status() :: {reference(), :shown | :changed | :standing, String.t() | nil}

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t(),
          room: String.t(),
          posting: WardrikChannel.Channel.t() | nil,
          showing: showing() | nil,
          followers: pid() | nil,
          threads: %{String.t() => thread()},
          retries: %{String.t() => retry()},
          statuses: %{String.t() => status()}
        }

  @typedoc """
  What an event asks to be posted in its thread: what a run answered, and
  the messages it answers; the calls a run waits on; why a run failed; that
  someone connected an account a call waited on, by the provider's name; who
  decided a call, and how; that a run stopped before it answered, with the
  messages it would have answered; or nothing.
  """
  @type post() ::
          {:reply, String.t(), [String.t()]}
          | {:parked, [String.t()]}
          | {:failed, String.t()}
          | {:connected, String.t()}
          | {:decided, String.t()}
          | {:stopped, [String.t()]}
          | :none

  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(channel, workspace, room),
    do: %__MODULE__{channel: channel, workspace: workspace, room: room}

  @doc """
  The same room, posting through `channel`, showing statuses as `showing`
  says, with its threads' followers under the supervisor `followers`.
  """
  @spec posting(t(), WardrikChannel.Channel.t(), showing(), pid()) :: t()
  def posting(%__MODULE__{} = state, channel, showing, followers),
    do: %{state | posting: channel, showing: showing, followers: followers}

  @doc """
  Follows `agent` in `thread`, posting what its log holds after `cursor`,
  unless the thread is followed already.
  """
  @spec follow(t(), String.t(), Thread.t(), String.t()) :: t()
  def follow(%__MODULE__{} = state, thread, %Thread{} = agent, cursor) do
    followed = %{agent: agent, cursor: cursor, runs: %{}}
    %{state | threads: Map.put_new(state.threads, thread, followed)}
  end

  @doc "Whether `thread` is followed."
  @spec followed?(t(), String.t()) :: boolean()
  def followed?(%__MODULE__{threads: threads}, thread), do: Map.has_key?(threads, thread)

  @doc """
  What `event`, the next in `thread`'s log, asks to be posted, and the state
  once it has been, with `cursor`, past it.
  """
  @spec take(t(), String.t(), map(), String.t()) :: {post(), t()}
  def take(%__MODULE__{} = state, thread, event, cursor) do
    followed = Map.fetch!(state.threads, thread)
    {post, runs} = post(event, followed.runs)
    followed = %{followed | cursor: cursor, runs: runs}
    {post, %{state | threads: Map.put(state.threads, thread, followed)}}
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

  defp post(%{"type" => "wardrik.run.cancelled", "data" => data}, runs) do
    {answering, runs} = Map.pop(runs, data["run"]["id"], [])
    {{:stopped, answering}, runs}
  end

  # A call is decided by an authorization, rather than by a person, where an
  # account it waited on was connected.
  defp post(
         %{
           "type" => "wardrik.interrupt.resolved",
           "data" => %{"resolved_by" => %{"id" => "oauth:" <> provider}}
         },
         runs
       ),
       do: {{:connected, provider}, runs}

  defp post(
         %{
           "type" => "wardrik.interrupt.resolved",
           "data" => %{"resolved_by" => %{"id" => id} = by} = data
         },
         runs
       ),
       do:
         {{:decided, decided(data["decision"], by["name"] || id, data["note"] || data["reason"])},
          runs}

  defp post(_event, runs), do: {:none, runs}

  defp decided("approved", name, nil), do: "Approved by #{name}."
  defp decided("approved", name, note), do: "Approved by #{name}: #{note}"
  defp decided(_rejected, name, nil), do: "Denied by #{name}."

  # A reason that says who denied the call, as a channel's own does, is said
  # as it is.
  defp decided(_rejected, _name, "Denied " <> _said = reason), do: reason
  defp decided(_rejected, name, reason), do: "Denied by #{name}: #{reason}"

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
