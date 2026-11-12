defmodule WardrikStore.Counter do
  @moduledoc "A durable server the tests keep in a store."
  use DurableServer, vsn: 1

  def dump_state(state), do: %{count: state.count}
  def load_state(_old_vsn, %{count: count}), do: %{count: count}

  def init(state), do: {:ok, state}

  def handle_call(:increment, _from, state) do
    state = %{state | count: state.count + 1}
    {:reply, state.count, state, :sync}
  end

  def handle_call(:count, _from, state), do: {:reply, state.count, state}
end
