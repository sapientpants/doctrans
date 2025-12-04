defmodule Doctrans.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :title, :string, null: false
      add :original_filename, :string, null: false
      add :total_pages, :integer
      add :status, :string, null: false, default: "uploading"
      add :source_language, :string, null: false
      add :target_language, :string, null: false
      add :error_message, :text

      timestamps()
    end

    create index(:documents, [:status])
    create index(:documents, [:inserted_at])
  end
end
