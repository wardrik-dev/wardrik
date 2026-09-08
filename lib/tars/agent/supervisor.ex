defmodule Tars.Agent.Supervisor do
  @moduledoc """
  Supervisor for managing Tars agents.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start(agent_name, llm \\ Tars.LLM.new(), tools \\ []) do
    spec = {Tars.Agent, [name: agent_name, llm: llm, tools: tools]}

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
