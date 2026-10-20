defmodule Wardrik.Event.Source do
  @moduledoc """
  Who is emitting: the topic subscribers watch, and the span the work sits in.

  The two always travel together, so they are one value rather than two
  arguments every caller has to pair up. Nested work keeps the topic and takes
  a child span, which is what puts a subagent's events in its parent's stream
  without a second subscription.

      source = Wardrik.Event.Source.root(~A"acme/@jon/assistant", name: "turn")
      branch = Wardrik.Event.Source.child(source, name: "web_search")

      branch.agent_id == source.agent_id
  """

  alias Wardrik.Trace

  @enforce_keys [:agent_id, :trace]
  defstruct [:agent_id, :trace]

  @typedoc "An agent id to publish under, and the span the events belong to."
  @type t() :: %__MODULE__{agent_id: Wardrik.Event.Bus.agent_id(), trace: Trace.t()}

  @doc """
  A source at the root of a new trace.

  Options are passed to `Wardrik.Trace.root/1`.
  """
  @spec root(Wardrik.Event.Bus.agent_id(), keyword()) :: t()
  def root(agent_id, opts \\ []) do
    %__MODULE__{agent_id: agent_id, trace: Trace.root(opts)}
  end

  @doc """
  A source for work that `source` spawned: same topic, a child span.

  Options are passed to `Wardrik.Trace.child/2`.
  """
  @spec child(t(), keyword()) :: t()
  def child(%__MODULE__{} = source, opts \\ []) do
    %{source | trace: Trace.child(source.trace, opts)}
  end
end
