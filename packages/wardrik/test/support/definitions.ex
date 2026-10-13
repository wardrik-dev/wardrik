defmodule Wardrik.Test.Definitions do
  @moduledoc false
  # The suite's host's definitions, which config/test.exs names: the spec a
  # test keeps for an agent is the one it starts and wakes on, and an agent
  # nothing kept for starts as it was given.
  use Wardrik.Definition

  @ns :test_definitions

  @impl true
  def current(id) do
    case WardrikStore.get(@ns, to_string(id)) do
      nil -> :none
      spec -> {:ok, spec}
    end
  end

  @spec keep(Wardrik.AgentID.t(), Wardrik.Agent.Spec.t()) :: :ok
  def keep(id, spec) do
    {:ok, _vsn} = WardrikStore.put(@ns, to_string(id), spec)
    :ok
  end
end
