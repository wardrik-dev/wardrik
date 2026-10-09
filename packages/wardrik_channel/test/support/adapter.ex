defmodule WardrikChannel.Test.Adapter do
  @moduledoc "A channel that tells the test process what it was asked to post."
  @behaviour WardrikChannel

  @impl WardrikChannel
  def config(%{"test" => test}), do: {:ok, test: test}
  def config(_settings), do: {:error, ["test"], "is required"}

  @impl WardrikChannel
  def child_spec(opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> opts end]}}

  @impl WardrikChannel
  def deliver(outbound, opts) do
    send(opts[:test], {:delivered, outbound, opts})
    if outbound.room == "#nowhere", do: {:error, :no_room}, else: {:ok, :posted}
  end
end
