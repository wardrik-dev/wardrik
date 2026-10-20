defmodule Wardrik.Agent.State.Stored do
  @moduledoc """
  A `Wardrik.Agent.State` written down as data, and read back on whichever
  node holds the agent next.

  A turn in flight is written as the `Wardrik.Agent.State.Due` turn it comes
  back as, from its `recovery`; see `Wardrik.Agent.State`. A waiting turn
  keeps its source, and its clock starts again where it is read back. Each
  keeps who asked for it. A turn began on the history the agent holds, so it
  is written as only what it added, and read back on that history; see
  `Wardrik.Turn.dump/1`. How far
  the agent's `Wardrik.Event.Log` has got is written as a sequence number,
  from which the next owner looks for the head. The `Wardrik.Host` it runs
  on is never written: whichever node loads it next hands it its own. Nor is
  its `Wardrik.Agent.Activity`, which is read back from what it waits on.
  """

  alias Wardrik.Agent.Activity
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.State
  alias Wardrik.Agent.State.Due
  alias Wardrik.Agent.State.Running
  alias Wardrik.Agent.State.Waiting
  alias Wardrik.Bus
  alias Wardrik.Bus.Source
  alias Wardrik.Conversation
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Runtime.Settings
  alias Wardrik.Turn

  @typedoc "An agent written down: what it is, what it was asked, and what it is waiting on."
  @type t() :: %{
          generation: String.t(),
          agent_id: Bus.agent_id(),
          sequence: non_neg_integer(),
          config: Settings.t(),
          history: Conversation.t(),
          run_opts: keyword(),
          grace: pos_integer(),
          pending: [Message.t()],
          recent: [String.t()],
          outcome: State.outcome(),
          labels: [Wardrik.Label.t()],
          mode: :idle | Due.t() | {:waiting, Turn.t(), Source.t(), Wardrik.Principal.t() | nil}
        }

  @doc "Writes `state` down as data."
  @spec dump(State.t()) :: t()
  def dump(%State{} = state) do
    state
    |> Map.from_struct()
    |> Map.drop([:log, :host, :active_at, :idle_timer, :activity])
    |> Map.merge(%{
      config: Settings.dump(state.config),
      mode: at_rest(state.mode),
      sequence: state.log.head
    })
  end

  defp at_rest(%Waiting{turn: turn, source: source, sender: sender}),
    do: {:waiting, Turn.dump(turn), source, sender}

  defp at_rest(%Running{recovery: :owed, run: run}),
    do: %Due{recovery: :owed, sender: run.sender}

  defp at_rest(%Running{recovery: recovery, run: run}),
    do: at_rest(%Due{recovery: recovery, source: run.source, sender: run.sender})

  defp at_rest(%Due{recovery: recovery} = due), do: %{due | recovery: dumped(recovery)}
  defp at_rest(:idle), do: :idle

  defp dumped({:replaying, checkpoint}), do: {:replaying, Turn.dump(checkpoint)}
  defp dumped({:resuming, turn, decisions}), do: {:resuming, Turn.dump(turn), decisions}
  defp dumped(:owed), do: :owed

  @doc "Reads an agent back from `dump/1`, with the tools this node can build."
  @spec load(t()) :: State.t()
  def load(%{agent_id: agent_id, config: config, mode: mode} = dumped) do
    {sequence, dumped} = Map.pop(dumped, :sequence, 0)
    dumped = Map.put(dumped, :log, Writer.new(agent_id, sequence))

    struct!(
      State,
      Map.merge(dumped, %{
        config: Settings.load(config),
        mode: reopen(mode, dumped.history),
        host: Wardrik.Host.new(),
        activity: %Activity{
          doing: doing(mode),
          since: System.system_time(:microsecond),
          pending: length(dumped.pending)
        }
      })
    )
  end

  # What it is doing as it is read back: waiting on a person, or nothing
  # until a turn starts.
  defp doing({:waiting, turn, _source, _sender}), do: %Bus.TurnParked{calls: Turn.waiting(turn)}
  defp doing(_mode), do: :idle

  @doc """
  What an agent written down waits on, as `{call, prompt}` pairs, or `[]`
  when it is not parked. Read without loading the agent.
  """
  @spec waiting_on(t()) :: [{Wardrik.Tool.call(), String.t()}]
  def waiting_on(%{mode: {:waiting, turn, _source, _sender}}), do: Turn.waiting(turn)
  def waiting_on(%{}), do: []

  @doc "The ids of the calls an agent written down parked to resolve `ref` for `owner`."
  @spec awaiting(t(), Wardrik.Credential.ref(), Wardrik.Credential.owner()) :: [String.t()]
  def awaiting(%{mode: {:waiting, turn, _source, _sender}}, ref, owner),
    do: Turn.awaiting(turn, ref, owner)

  def awaiting(%{}, _ref, _owner), do: []

  defp reopen({:waiting, turn, source, sender}, history) do
    %Waiting{
      turn: Turn.load(turn, history),
      source: source,
      sender: sender,
      started_at: System.monotonic_time()
    }
  end

  defp reopen(%Due{recovery: recovery} = due, history),
    do: %{due | recovery: loaded(recovery, history)}

  defp reopen(:idle, _history), do: :idle

  defp loaded({:replaying, checkpoint}, history), do: {:replaying, Turn.load(checkpoint, history)}

  defp loaded({:resuming, turn, decisions}, history),
    do: {:resuming, Turn.load(turn, history), decisions}

  defp loaded(:owed, _history), do: :owed
end
