defmodule WardrikDaemon.Test.Channel do
  @moduledoc "A channel adapter for the daemon's tests, `type: test`: it runs nothing and posts nowhere."
  @behaviour WardrikChannel

  @impl WardrikChannel
  def config(%{"room_prefix" => prefix}) when is_binary(prefix), do: {:ok, room_prefix: prefix}
  def config(settings) when map_size(settings) == 0, do: {:ok, []}
  def config(_settings), do: {:error, ["room_prefix"], "is the only setting"}

  @impl WardrikChannel
  def child_spec(opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> opts end]}}

  @impl WardrikChannel
  def deliver(_outbound, _opts), do: {:ok, :posted}

  @impl WardrikChannel
  def among?(user, names, _opts), do: user in names
end
