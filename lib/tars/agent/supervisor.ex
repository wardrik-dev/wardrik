defmodule Tars.Agent.Supervisor do
  @moduledoc """
  Supervises the running agents.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start an agent under supervision.

  `opts` are passed through to `Tars.Agent`, so `:context` and `:runner` can be
  set here too. `agent_name` doubles as the agent's event id — subscribe to it
  with `Tars.Events.subscribe/1`.
  """
  @spec start(GenServer.name(), keyword()) :: DynamicSupervisor.on_start_child()
  def start(agent_name, opts \\ []) do
    spec = {Tars.Agent, Keyword.merge(opts, name: agent_name)}

    DynamicSupervisor.start_child(Tars.Agent.Supervisor, spec)
  end
end
