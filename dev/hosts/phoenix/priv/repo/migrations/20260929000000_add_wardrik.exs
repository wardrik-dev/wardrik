defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: Wardrik.Migration.up(version: 1)
  def down, do: Wardrik.Migration.down(version: 1)
end
