defmodule Wardrik.Operations.Spawning do
  @moduledoc """
  The effect of starting an agent: how it starts, and where.

  `start` is what its plan found:

    * `:running` - it runs already, and nothing happens
    * `:asleep` - it is stored, and wakes from what it had, as the host's
      `c:Wardrik.Definition.current/1` says it is now
    * `{:defined, spec}` - the host defines it, and it starts on that spec,
      with whatever it had stored
    * `:new` - nothing defines it yet, and the host's
      `c:Wardrik.Definition.create/1` defines it as it starts

  `on` is the node it starts on, or `:anywhere` for wherever the fleet puts
  it; once made, the node it runs on.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.AgentOperation
  alias Wardrik.Error
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member
  alias Wardrik.Host
  alias Wardrik.Resource

  @enforce_keys [:agent, :start, :on]
  defstruct [:agent, :start, :on]

  @type start() :: :running | :asleep | {:defined, Spec.t()} | :new

  @type t() :: %__MODULE__{agent: AgentID.t(), start: start(), on: node() | :anywhere}

  @doc """
  The effect of starting the agent `id` on `on`, on `host`, or why it
  cannot start: one that runs already runs on, one the host defines starts
  on its definition, one asleep wakes, and one nothing defines is defined
  as it starts.
  """
  @spec of(Host.t(), AgentID.t(), node() | :anywhere) :: {:ok, t()} | {:error, Error.t()}
  def of(host, %AgentID{} = id, on) do
    member = Fleet.lookup(id)

    case {member, Host.definitions(host).current(id)} do
      {%Member{asleep: false, node: node}, _current} ->
        {:ok, %__MODULE__{agent: id, start: :running, on: node}}

      {_member, {:ok, spec}} ->
        {:ok, %__MODULE__{agent: id, start: {:defined, spec}, on: on}}

      {%Member{asleep: true}, :none} ->
        {:ok, %__MODULE__{agent: id, start: :asleep, on: on}}

      {nil, :none} ->
        {:ok, %__MODULE__{agent: id, start: :new, on: on}}
    end
  end

  @doc """
  Starts the agent as `effect` says, on `host`: the effect made, with the
  node it runs on. One nothing defines is not found where the host creates
  none.
  """
  @spec make(Host.t(), t()) :: {:ok, t()} | {:error, Error.t()}
  def make(_host, %__MODULE__{start: :running} = effect), do: {:ok, effect}

  def make(_host, %__MODULE__{agent: id, start: :asleep, on: on} = effect),
    do: id |> Fleet.spawn(placed(on)) |> made(effect)

  def make(_host, %__MODULE__{start: {:defined, spec}, on: on} = effect),
    do: spec |> started(on) |> made(effect)

  def make(host, %__MODULE__{agent: id, start: :new, on: on} = effect) do
    case Host.definitions(host).create(id) do
      {:ok, spec} -> spec |> started(on) |> made(effect)
      {:error, :conflict, why} -> {:error, Error.new(:conflict, why)}
      {:error, why} -> {:error, Error.new(:invalid, why)}
      :unsupported -> {:error, AgentOperation.not_found(id)}
    end
  end

  # An agent bound for a node is started there first, then given its spec.
  defp started(spec, :anywhere), do: Fleet.put(spec)

  defp started(spec, node) do
    with {:ok, _pid} <- Fleet.spawn(spec.id, Spec.options(spec) ++ [node: node]),
         do: Fleet.put(spec)
  end

  defp placed(:anywhere), do: []
  defp placed(node), do: [node: node]

  defp made({:ok, pid}, effect), do: {:ok, %{effect | on: node(pid)}}

  defp made({:error, reason}, %__MODULE__{agent: id}),
    do: {:error, Error.new(:unavailable, "#{id} did not start: #{inspect(reason)}")}

  @doc "What a start answers once made: the agent as the fleet lists it, and how it started."
  @spec answer(t()) :: map()
  def answer(%__MODULE__{agent: id} = effect),
    do: %{"agent" => Resource.agent(Fleet.lookup(id)), "from" => from(effect)}

  @doc false
  @spec from(t()) :: String.t()
  def from(%__MODULE__{start: :running}), do: "running"
  def from(%__MODULE__{start: :asleep}), do: "store"
  def from(%__MODULE__{start: {:defined, _spec}}), do: "definition"
  def from(%__MODULE__{start: :new}), do: "new"

  defimpl Wardrik.Effect do
    alias Wardrik.Operations.Spawning

    def preview(%{agent: id, on: on} = effect) do
      spawning = %{"agent" => to_string(id), "from" => Spawning.from(effect)}

      %{
        "spawning" =>
          if(on == :anywhere, do: spawning, else: Map.put(spawning, "on", to_string(on)))
      }
    end

    def audit(%{start: :running}), do: []
    def audit(%{agent: id, on: on}), do: [{:agent_spawned, id, on}]
  end
end
