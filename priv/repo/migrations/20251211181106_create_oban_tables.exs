defmodule Doctrans.Repo.Migrations.CreateObanTables do
  use Ecto.Migration

  def change do
    Oban.Migration.up()
  end
end
