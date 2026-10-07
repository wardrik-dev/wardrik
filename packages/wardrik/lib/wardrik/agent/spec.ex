defmodule Wardrik.Agent.Spec do
  @moduledoc """
  An agent, written down: its ID, the config its turns run with, and the seams
  a host supplies.

      spec =
        Wardrik.Agent.Spec.new(
          id: Wardrik.AgentID.new!("triage", org: "acme"),
          description: "Watches the incident queue.",
          config: Wardrik.LLM.Config.new(system: "You watch the incident queue."),
          hooks: [Wardrik.Hook.new("careful", MyApp.Hook)],
          timeout: :timer.minutes(10)
        )

      {:ok, pid} = Wardrik.Fleet.put(spec)

  A spec holds no process and no function, so it can be written to a file,
  sent to another node, or read back from either. `Wardrik.Fleet.put/1` makes the
  fleet match it: an agent is started under its ID where none runs, and given
  the spec's config and seams where one does, and its schedules are brought to
  the spec's. A spec whose `:schedules` is `nil` leaves them as they are.

  | Field | What it is |
  | --- | --- |
  | `:id` | the agent's `Wardrik.AgentID` |
  | `:description` | what it is for, in words a person reads |
  | `:config` | a `Wardrik.LLM.Config` |
  | `:schedules` | the `Wardrik.Schedule`s that ask it on a clock, `[]` by default; `nil` leaves the agent's own |
  | `:hooks`, `:dispatch`, `:credentials`, `:ledger`, `:timeout` | the seams of `Wardrik.Scope.seams/0` |
  """

  alias Wardrik.AgentID
  alias Wardrik.LLM.Config
  alias Wardrik.Scope

  @enforce_keys [:id, :config]
  defstruct [:id, :description, :config, schedules: []] ++ Scope.seams()

  @type t() :: %__MODULE__{
          id: AgentID.t(),
          description: String.t() | nil,
          config: Config.t(),
          schedules: [Wardrik.Schedule.t()] | nil,
          hooks: [Wardrik.Hook.t()] | nil,
          dispatch: Wardrik.LLM.Dispatch.t() | nil,
          credentials: module() | nil,
          ledger: module() | nil,
          timeout: timeout() | nil
        }

  @doc """
  A spec from its fields. `:id` is required, and `:config` is
  `Wardrik.LLM.Config.new/0` unless given. Raises on a field a spec does not
  have.
  """
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields),
    do: struct!(__MODULE__, Keyword.put_new_lazy(fields, :config, &Config.new/0))

  @doc """
  What `Wardrik.Fleet.spawn/2` and `Wardrik.Agent.configure/2` take: the config, and
  each seam the spec sets.
  """
  @spec options(t()) :: keyword()
  def options(%__MODULE__{} = spec) do
    seams =
      Enum.flat_map(Scope.seams(), fn seam ->
        case Map.fetch!(spec, seam) do
          nil -> []
          value -> [{seam, value}]
        end
      end)

    [config: spec.config] ++ seams
  end
end
