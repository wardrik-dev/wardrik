defmodule WardrikChannel.Installations.Token do
  @moduledoc """
  The single installation a channel's `token:` makes, in the workspace that token reaches.

      slack: {WardrikSlack, token: "xoxb-...", owner: "acme", identities: {MyApp.ChatMembers, []}}

  Adding other installations returns an error. Forgetting one does nothing. Found by its owner,
  its workspace is `"*"`.
  """

  @behaviour Wardrik.Channel.Installations

  alias Wardrik.Channel.Installation
  alias Wardrik.Channel.Installations.Request

  @impl Wardrik.Channel.Installations
  def fetch(%Request{channel: channel, workspace: workspace}, config) do
    {:ok,
     %Installation{
       channel: channel,
       workspace: workspace,
       owner: Keyword.fetch!(config, :owner),
       token: Keyword.fetch!(config, :token)
     }}
  end

  @impl Wardrik.Channel.Installations
  def owned(%Request{channel: channel, owner: owner}, config) do
    if Keyword.fetch!(config, :owner) == owner,
      do: [elem(fetch(%Request{channel: channel, workspace: "*"}, config), 1)],
      else: []
  end

  @impl Wardrik.Channel.Installations
  def put(%Installation{channel: channel}, _config),
    do: {:error, "#{channel} is added with its token, and in no other way."}

  @impl Wardrik.Channel.Installations
  def delete(%Request{}, _config), do: :ok
end
