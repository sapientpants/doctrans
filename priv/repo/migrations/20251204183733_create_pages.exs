defmodule Doctrans.Repo.Migrations.CreatePages do
  use Ecto.Migration

  def change do
    create table(:pages, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :document_id, references(:documents, type: :uuid, on_delete: :delete_all), null: false
      add :page_number, :integer, null: false
      add :image_path, :string
      add :original_markdown, :text
      add :translated_markdown, :text
      add :extraction_status, :string, null: false, default: "pending"
      add :translation_status, :string, null: false, default: "pending"

      timestamps()
    end

    create index(:pages, [:document_id])
    create index(:pages, [:document_id, :page_number], unique: true)
    create index(:pages, [:extraction_status])
    create index(:pages, [:translation_status])
  end
end
