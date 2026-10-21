defmodule MyApp.Slack do
  @moduledoc """
  The app's Slack app, in each org's own workspace: the channel's settings,
  and, as its `WardrikChannel.Installations`, the workspaces it was added
  to. Bot tokens are sealed in the vault as the deployment's, so no agent's
  call reaches them. What someone in a workspace may do, the channel says
  (`WardrikChannel.Issuer`).
  """

  import Ecto.Query

  alias MyApp.Slack.Workspace

  defstruct []

  @doc "The channel's settings, as `WardrikChannel.attach/2` takes them."
  def settings do
    [
      channels: [slack: adapter()],
      installations: %__MODULE__{},
      offering: "An admin of your org can offer one by turning on Slack in the agent's settings.",
      deciding: "Your org's admins name the approvers in its Slack settings."
    ]
  end

  @doc "The channel, as the app's instance runs it."
  def channel, do: WardrikChannel.channel(MyApp.Agents, "slack")

  @doc "The vault the bot tokens are sealed in, with the key the agents' credentials are."
  def vault,
    do:
      WardrikVault.new(
        store: Wardrik.store(repo: MyApp.Repo),
        keys: [System.fetch_env!("WARDRIK_VAULT_KEY")]
      )

  @doc "Has `names`, each a `@handle`, an email address or a member ID, approve in `team`'s workspace."
  def approvers(team, names),
    do:
      MyApp.Repo.update_all(from(w in Workspace, where: w.team == ^team), set: [approvers: names])

  defp adapter do
    {:ok, options} =
      WardrikSlack.config(%{
        "client_id" => System.fetch_env!("SLACK_CLIENT_ID"),
        "client_secret" => System.fetch_env!("SLACK_CLIENT_SECRET"),
        "signing_secret" => System.fetch_env!("SLACK_SIGNING_SECRET")
      })

    {WardrikSlack, options}
  end
end

defimpl WardrikChannel.Installations, for: MyApp.Slack do
  import Ecto.Query

  alias MyApp.Slack.Workspace
  alias Wardrik.Resource
  alias WardrikChannel.Installation

  def fetch(_slack, channel, team) do
    with %Workspace{} = workspace <- MyApp.Repo.get(Workspace, team),
         {:ok, token} <- token(team) do
      {:ok, installation(channel, workspace, token)}
    else
      _not_added -> :error
    end
  end

  def owned(_slack, channel, owner) do
    for workspace <- MyApp.Repo.all(from(w in Workspace, where: w.org == ^to_string(owner))),
        {:ok, token} <- [token(workspace.team)],
        do: installation(channel, workspace, token)
  end

  def put(_slack, %Installation{workspace: team, owner: owner, token: token}) do
    org = to_string(owner)

    case MyApp.Repo.get(Workspace, team) do
      %Workspace{org: other} when other != org ->
        {:error, "That Slack workspace answers for another org. Remove the app there first."}

      _ours_or_new ->
        :ok =
          WardrikVault.put(MyApp.Slack.vault(), name(team), Resource.deployment(), value: token)

        MyApp.Repo.insert!(%Workspace{team: team, org: org}, on_conflict: :nothing)
        :ok
    end
  end

  def delete(_slack, _channel, team) do
    MyApp.Repo.delete_all(from(w in Workspace, where: w.team == ^team))
    :ok = WardrikVault.forget(MyApp.Slack.vault(), name(team), Resource.deployment())
  end

  defp token(team),
    do: WardrikVault.fetch(MyApp.Slack.vault(), name(team), Resource.deployment())

  defp name(team), do: "slack-" <> team

  defp installation(channel, workspace, token),
    do: %Installation{
      channel: channel,
      workspace: workspace.team,
      owner: Resource.parse!(workspace.org),
      token: token,
      approvers: %WardrikChannel.Approvers.Named{names: workspace.approvers}
    }
end
