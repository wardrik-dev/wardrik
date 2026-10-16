defmodule Wardrik.Test.Definitions do
  @moduledoc false
  # The suite's host's definitions, which config/test.exs names: the spec a
  # test keeps for an agent is the one it starts and wakes on, and an agent
  # nothing kept for starts as it was given.
  defstruct []

  @ns :test_definitions
  def current(_host, id) do
    case WardrikStore.get(Wardrik.Test.store(), @ns, to_string(id)) do
      nil -> :none
      spec -> {:ok, spec}
    end
  end

  @spec keep(Wardrik.AgentID.t(), Wardrik.Agent.Spec.t()) :: :ok
  def keep(id, spec) do
    {:ok, _vsn} = WardrikStore.put(Wardrik.Test.store(), @ns, to_string(id), spec)
    :ok
  end
end

defimpl Wardrik.Definition, for: Wardrik.Test.Definitions do
  use Wardrik.Definition.None
  defdelegate current(a0, a1), to: Wardrik.Test.Definitions
end
