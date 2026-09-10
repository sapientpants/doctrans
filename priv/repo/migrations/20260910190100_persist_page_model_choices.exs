defmodule Doctrans.Repo.Migrations.PersistPageModelChoices do
  use Ecto.Migration

  def change do
    alter table(:pages) do
      add :processing_generation, :uuid
      add :requested_extraction_model, :string
      add :requested_translation_model, :string
    end
  end
end
