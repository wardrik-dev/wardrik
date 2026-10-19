defmodule WardrikSlack.Test do
  @moduledoc """
  What the tests post through: an installation of a channel in a workspace,
  with the token given.
  """

  alias WardrikChannel.Installation

  @doc "A host reading definitions under `Wardrik.context(fields)`, with `opts` among its own."
  def host(fields \\ [], opts \\ []),
    do: Wardrik.new([store: Wardrik.Test.store(), context: Wardrik.context(fields)] ++ opts)

  @doc "Keeps the definition `fields` write for `id` on `host`, as the host wrote it."
  def define(host, id, fields) do
    definitions = Wardrik.Host.definitions(host)

    {:ok, definition} =
      Wardrik.Definition.read(fields,
        id: id,
        source: :defaults,
        context: Wardrik.Definitions.context(definitions, id)
      )

    :ok = Wardrik.Definitions.put(definitions, definition)
    id
  end

  @doc "The installation of the channel `slack` in the workspace T1, with `token`."
  @spec installation(String.t()) :: Installation.t()
  def installation(token \\ "xoxb-test"),
    do: %Installation{
      channel: "slack",
      workspace: "T1",
      owner: Wardrik.Resource.parse!("*"),
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
