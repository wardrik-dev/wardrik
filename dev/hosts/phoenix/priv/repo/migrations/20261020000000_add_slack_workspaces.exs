defmodule MyApp.Repo.Migrations.AddSlackWorkspaces do
  use Ecto.Migration

  def change do
    create table(:slack_workspaces, primary_key: false) do
      add :team, :text, primary_key: true
      add :org, :text, null: false
      add :approvers, {:array, :text}, null: false, default: []
    end
  end
end
