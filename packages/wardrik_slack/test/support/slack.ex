defmodule WardrikSlack.Test do
  @moduledoc """
  What the tests post through: an installation of a channel in a workspace,
  with the token given.
  """

  alias WardrikChannel.Installation

  @doc "The installation of the channel `slack` in the workspace T1, with `token`."
  @spec installation(String.t()) :: Installation.t()
  def installation(token \\ "xoxb-test"),
    do: %Installation{
      channel: "slack",
      workspace: "T1",
      owner: Wardrik.AgentID.Prefix.all(),
      token: token
    }
end

defmodule WardrikSlack.Test.Installations do
  @moduledoc "A test's installations, kept in an `Agent` by channel and workspace."
  @enforce_keys [:agent]
  defstruct [:agent]

  defimpl WardrikChannel.Installations do
    def fetch(%{agent: agent}, channel, workspace),
      do: Agent.get(agent, &Map.fetch(&1, {channel, workspace}))

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
