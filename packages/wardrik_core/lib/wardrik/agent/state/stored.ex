defmodule Wardrik.Agent.State.Stored do
  @moduledoc """
  A `Wardrik.Agent.State` written down as data, and read back on whichever
  node holds the agent next.

  A turn in flight is written as the `Wardrik.Agent.State.Due` turn it comes
  back as, from its `recovery`; see `Wardrik.Agent.State`. A waiting turn
  keeps its source, and its clock starts again where it is read back. Each
  keeps who asked for it. How far
  the agent's `Wardrik.Event.Log` has got is written as a sequence number,
  from which the next owner looks for the head. The `Wardrik.Host` it runs
  on is never written: whichever node loads it next hands it its own.
  """

  alias ReqLLM.Context
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.State
  alias Wardrik.Agent.State.Due
  alias Wardrik.Agent.State.Running
  alias Wardrik.Agent.State.Waiting
  alias Wardrik.Event
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Event.Source
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Turn

  @typedoc "An agent written down: what it is, what it was asked, and what it is waiting on."
  @type t() :: %{
          generation: String.t(),
          agent_id: Event.Bus.agent_id(),
          sequence: non_neg_integer(),
          config: Config.dumped(),
          context: Context.t(),
          scope_opts: keyword(),
          grace: pos_integer(),
          pending: [Message.t()],
          recent: [String.t()],
          runner: State.runner(),
          resumer: State.resumer(),
          outcome: State.outcome(),
          labels: [Wardrik.Label.t()],
          mode: :idle | Due.t() | {:waiting, Turn.t(), Source.t(), Wardrik.Principal.t() | nil}
        }

  @doc "Writes `state` down as data."
  @spec dump(State.t()) :: t()
  def dump(%State{} = state) do
    state
    |> Map.from_struct()
    |> Map.drop([:log, :host, :active_at, :idle_timer])
    |> Map.merge(%{
      config: Config.dump(state.config),
      mode: at_rest(state.mode),
      sequence: state.log.head
    })
  end

  defp at_rest(%Waiting{turn: turn, source: source, sender: sender}),
    do: {:waiting, turn, source, sender}

  defp at_rest(%Running{recovery: :owed, scope: scope}),
    do: %Due{recovery: :owed, sender: scope.sender}

  defp at_rest(%Running{recovery: recovery, scope: scope}),
    do: %Due{recovery: recovery, source: scope.source, sender: scope.sender}

  defp at_rest(mode), do: mode

  @doc "Reads an agent back from `dump/1`, with the tools this node can build."
  @spec load(t()) :: State.t()
  def load(%{agent_id: agent_id, config: config, mode: mode} = dumped) do
    {sequence, dumped} = Map.pop(dumped, :sequence, 0)
    dumped = Map.put(dumped, :log, Writer.new(agent_id, sequence))

    struct!(
      State,
      Map.merge(dumped, %{
        config: Config.load(config),
        mode: reopen(mode),
        host: Wardrik.Host.new()
      })
    )
  end

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

  defp reopen({:waiting, turn, source, sender}),
    do: %Waiting{turn: turn, source: source, sender: sender, started_at: System.monotonic_time()}

  defp reopen(mode), do: mode
end
