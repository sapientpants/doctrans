defmodule Doctrans.Repo.Migrations.CreateBooks do
  use Ecto.Migration

  def change do
    create table(:books, primary_key: false) do
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

    create index(:books, [:status])
    create index(:books, [:inserted_at])
  end
end
