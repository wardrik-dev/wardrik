defmodule MyApp.Repo.Migrations.AddAgentEvents do
  use Ecto.Migration

  def change do
    create table(:agent_events, primary_key: false) do
      add :id, :text, primary_key: true
      add :agent, :text, null: false
      add :type, :text, null: false
      add :data, :map, null: false
      add :at, :utc_datetime_usec, null: false
    end

    create table(:wardrik_cursors, primary_key: false) do
      add :name, :text, primary_key: true
      add :cursor, :text, null: false
    end
  end
end
