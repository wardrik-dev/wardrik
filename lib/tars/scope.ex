defmodule Tars.Scope do
  @moduledoc """
  Everything one run needs that nobody configures.

  `Tars.LLM.Config` is supplied by the caller; a scope is what the system
  builds around it to actually run a turn. Today that is the event source.
  Deadlines, cancellation, and store handles belong here too as they arrive,
  which keeps them out of the configuration a caller writes.

      scope = Tars.Scope.root(config, :assistant, name: "turn")
      Tars.Event.emit(scope.source, {:turn_started, ["hello"]})

  Work the turn spawns takes a child scope, so its events land in the same
  stream under a child span:

      branch = Tars.Scope.child(scope, name: "web_search")

  Work that should run under a different model or tool set takes that config
  where it is used, such as `Tars.Subagent.run/3`, rather than carrying it on
  a scope of its own.
  """

  alias Tars.Event.Bus
  alias Tars.Event.Source
  alias Tars.LLM.Config

  @enforce_keys [:config, :source]
  defstruct [:config, :source]

  @typedoc "The config a run was given, and where its events go."
  @type t() :: %__MODULE__{config: Config.t(), source: Source.t()}

  @doc """
  A scope at the root of a new trace.

  Options are passed to `Tars.Event.Source.root/2`.
  """
  @spec root(Config.t(), Bus.agent_id(), keyword()) :: t()
  def root(%Config{} = config, agent_id, opts \\ []) do
    %__MODULE__{config: config, source: Source.root(agent_id, opts)}
  end

  @doc """
  A scope for work that `scope` spawned: same config and topic, a child span.

  Options are passed to `Tars.Event.Source.child/2`.
  """
  @spec child(t(), keyword()) :: t()
  def child(%__MODULE__{} = scope, opts \\ []) do
    %{scope | source: Source.child(scope.source, opts)}
  end
end
