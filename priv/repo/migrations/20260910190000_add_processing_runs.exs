defmodule Doctrans.Repo.Migrations.AddProcessingRuns do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :processing_run_id, :uuid
      add :extraction_model, :string
      add :translation_model, :string
    end

    alter table(:pages) do
      add :extraction_model, :string
      add :translation_model, :string
    end
  end
end
