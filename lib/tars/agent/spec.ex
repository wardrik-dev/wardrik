defmodule Tars.Agent.Spec do
  @moduledoc """
  An agent, written down: what it is called and who it works for, the config
  its turns run with, and the seams a host supplies.

      spec =
        Tars.Agent.Spec.new(
          name: "triage",
          org: "acme",
          description: "Watches the incident queue.",
          config: Tars.LLM.Config.new(system: "You watch the incident queue."),
          hooks: [Tars.Hook.new("careful", MyApp.Hook)],
          timeout: :timer.minutes(10)
        )

      {:ok, pid} = Tars.Fleet.put(spec)

  A spec holds no process and no function, so it can be written to a file,
  sent to another node, or read back from either. `Tars.Fleet.put/1` makes the
  fleet match it: an agent is started under `key/1` where none runs, and given
  the spec's config and seams where one does, and its schedules are brought to
  the spec's. A spec whose `:schedules` is `nil` leaves them as they are.

  | Field | What it is |
  | --- | --- |
  | `:name` | the agent's name, the last part of its key |
  | `:org`, `:user` | who it works for, written into its key through `Tars.Fleet.Segment` |
  | `:description` | what it is for, in words a person reads |
  | `:config` | a `Tars.LLM.Config` |
  | `:schedules` | the `Tars.Schedule`s that ask it on a clock, `[]` by default; `nil` leaves the agent's own |
  | `:hooks`, `:dispatch`, `:credentials`, `:ledger`, `:timeout` | the seams of `Tars.Scope.seams/0` |
  """

  alias Tars.Fleet
  alias Tars.LLM.Config
  alias Tars.Scope

  @enforce_keys [:name, :config]
  defstruct [:name, :org, :user, :description, :config, schedules: []] ++ Scope.seams()

  @type t() :: %__MODULE__{
          name: String.t(),
          org: term(),
          user: term(),
          description: String.t() | nil,
          config: Config.t(),
          schedules: [Tars.Schedule.t()] | nil,
          hooks: [Tars.Hook.t()] | nil,
          dispatch: Tars.LLM.Dispatch.t() | nil,
          credentials: module() | nil,
          ledger: module() | nil,
          timeout: timeout() | nil
        }

  @doc """
  A spec from its fields. `:name` is required, and `:config` is
  `Tars.LLM.Config.new/0` unless given. Raises on a field a spec does not
  have, and on a name, org or user that `key/1` cannot write into a key.
  """
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields) do
    spec = struct!(__MODULE__, Keyword.put_new_lazy(fields, :config, &Config.new/0))
    _key = key(spec)
    spec
  end

  @doc "The agent's key in the fleet. See `Tars.Fleet.key/2`."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = spec), do: Fleet.key(spec.name, org: spec.org, user: spec.user)

  @doc """
  What `Tars.Fleet.spawn/2` and `Tars.Agent.configure/2` take: the config, and
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
