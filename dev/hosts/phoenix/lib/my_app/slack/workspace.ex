defmodule MyApp.Slack.Workspace do
  @moduledoc "A Slack workspace the app is added to: the org it answers for, and who approves there."

  use Ecto.Schema

  @primary_key {:team, :string, autogenerate: false}
  schema "slack_workspaces" do
    field :org, :string
    field :approvers, {:array, :string}, default: []
  end
end
