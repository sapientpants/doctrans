defmodule Doctrans.Repo.Migrations.CreateChunks do
  use Ecto.Migration

  def change do
    create table(:chunks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :page_id, references(:pages, type: :uuid, on_delete: :delete_all), null: false
      add :chunk_index, :integer, null: false
      add :content, :text, null: false
      add :translated_content, :text
      add :start_offset, :integer
      add :end_offset, :integer
      add :word_count, :integer
      add :embedding, :vector, size: 1024
      add :embedding_status, :string, null: false, default: "pending"

      timestamps()
    end

    create index(:chunks, [:page_id])
    create unique_index(:chunks, [:page_id, :chunk_index])
    create index(:chunks, [:embedding_status])
  end
end
