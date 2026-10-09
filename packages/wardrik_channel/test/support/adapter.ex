defmodule WardrikChannel.Test.Adapter do
  @moduledoc """
  A channel that tells the test process what it was asked to post. It
  refuses a post in `#nowhere`, and, given `:refusals`, an `Agent` holding a
  count, refuses that many posts first.
  """
  @behaviour WardrikChannel

  @impl WardrikChannel
  def config(%{"test" => test}), do: {:ok, test: test}
  def config(_settings), do: {:error, ["test"], "is required"}

  @impl WardrikChannel
  def child_spec(opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> opts end]}}

  @impl WardrikChannel
  def deliver(outbound, opts) do
    if refused?(opts[:refusals]) do
      send(opts[:test], {:refused, outbound})
      {:error, :busy}
    else
      send(opts[:test], {:delivered, outbound, opts})
      if outbound.room == "#nowhere", do: {:error, :no_room}, else: {:ok, :posted}
    end
  end

  defp refused?(nil), do: false

  defp refused?(refusals),
    do: Agent.get_and_update(refusals, fn left -> {left > 0, max(left - 1, 0)} end)
end
