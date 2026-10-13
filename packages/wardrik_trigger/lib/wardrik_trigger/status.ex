defmodule WardrikTrigger.Status do
  @moduledoc """
  One trigger as `WardrikTrigger.list/1` reports it, of either kind: its
  key, the agent it asks, when it runs as a person reads it, such as `every
  30m` or `on request`, the runs it has set, one for a trigger on a clock and
  none for a webhook, and when it last fired and what came of it.
  """

  @enforce_keys [:key, :pid, :agent, :name, :schedule, :next]
  defstruct [:key, :pid, :agent, :name, :schedule, :next, :last_at, :last_outcome]

  @type t() :: %__MODULE__{
          key: String.t(),
          pid: pid(),
          agent: Wardrik.AgentID.t(),
          name: String.t(),
          schedule: String.t(),
          next: [DateTime.t()],
          last_at: DateTime.t() | nil,
          last_outcome: WardrikTrigger.outcome() | nil
        }

  @doc "What a run that came to `outcome` did, as a person reads it."
  @spec described(WardrikTrigger.outcome() | nil) :: String.t()
  def described(nil), do: "asking"
  def described(:asked), do: "asked"
  def described(:nothing_new), do: "found nothing new"
  def described(:busy), do: "skipped, the agent was busy"
  def described(:no_agent), do: "no agent runs under the key"
  def described(:missed), do: "let a missed run go"
  def described(:failed), do: "failed"

  @doc false
  @spec new(String.t(), pid(), map()) :: t()
  def new(key, pid, meta) do
    struct!(__MODULE__, Map.merge(meta, %{key: key, pid: pid}))
  end
end
