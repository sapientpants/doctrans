defmodule Doctrans.Repo.Migrations.AddPageEmbeddings do
  use Ecto.Migration

  def change do
    alter table(:pages) do
      # qwen3-embedding:0.6b outputs 1024-dimensional vectors
      add :embedding, :vector, size: 1024
      add :embedding_status, :string, null: false, default: "pending"
    end

    # Create index for embedding status queries
    create index(:pages, [:embedding_status])

    # Note: IVFFlat vector indexes require data to exist first.
    # They will be created manually or via a separate migration
    # after initial data is populated:
    # CREATE INDEX pages_embedding_idx ON pages
    #   USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
  end
end
