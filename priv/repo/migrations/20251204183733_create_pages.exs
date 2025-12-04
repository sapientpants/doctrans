defmodule Doctrans.Repo.Migrations.CreatePages do
  use Ecto.Migration

  def change do
    create table(:pages, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :book_id, references(:books, type: :uuid, on_delete: :delete_all), null: false
      add :page_number, :integer, null: false
      add :image_path, :string
      add :original_markdown, :text
      add :translated_markdown, :text
      add :extraction_status, :string, null: false, default: "pending"
      add :translation_status, :string, null: false, default: "pending"

      timestamps()
    end

    create index(:pages, [:book_id])
    create index(:pages, [:book_id, :page_number], unique: true)
    create index(:pages, [:extraction_status])
    create index(:pages, [:translation_status])
  end
end
