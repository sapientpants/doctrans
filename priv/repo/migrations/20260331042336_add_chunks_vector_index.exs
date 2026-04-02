defmodule Doctrans.Repo.Migrations.AddChunksVectorIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS chunks_embedding_idx
    ON chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS chunks_embedding_idx;"
  end
end
