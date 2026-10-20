defmodule WardrikChannel.Test.Installations do
  @moduledoc """
  A test's installations, kept in an `Agent` by channel and workspace.
  """
  @enforce_keys [:agent]
  defstruct [:agent]

  defimpl WardrikChannel.Installations do
    def fetch(%{agent: agent}, channel, workspace),
      do: Agent.get(agent, &Map.fetch(&1, {channel, workspace}))

    def owned(%{agent: agent}, channel, owner),
      do: Agent.get(agent, &for({{^channel, _}, %{owner: ^owner} = held} <- &1, do: held))

    def put(%{agent: agent}, installation),
      do:
        Agent.update(
          agent,
          &Map.put(&1, {installation.channel, installation.workspace}, installation)
        )

    def delete(%{agent: agent}, channel, workspace),
      do: Agent.update(agent, &Map.delete(&1, {channel, workspace}))
  end
end
