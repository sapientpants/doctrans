defmodule Doctrans.Repo.Migrations.AddSourceExtension do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :source_extension, :string
    end
  end
end
