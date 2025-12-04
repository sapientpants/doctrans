defmodule Doctrans.Repo.Migrations.RemoveSourceLanguage do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      remove :source_language, :string
    end
  end
end
