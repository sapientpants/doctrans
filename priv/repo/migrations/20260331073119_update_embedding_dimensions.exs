defmodule Doctrans.Repo.Migrations.UpdateEmbeddingDimensions do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # The qwen3-embedding:8b model outputs 4096 dims natively, but we truncate
    # to 1024 in code (Matryoshka representation learning). This keeps HNSW
    # indexes viable (pgvector HNSW max is 2000 dims).
    #
    # This migration clears old embeddings from the previous model so they
    # can be regenerated, and recreates HNSW indexes.

    # Drop HNSW indexes first to avoid index maintenance overhead during mass updates
    execute "DROP INDEX CONCURRENTLY IF EXISTS pages_embedding_idx;"
    execute "DROP INDEX CONCURRENTLY IF EXISTS chunks_embedding_idx;"

    # Clear old embeddings (incompatible with new model)
    execute "UPDATE pages SET embedding = NULL, embedding_status = 'pending';"
    execute "UPDATE chunks SET embedding = NULL, embedding_status = 'pending';"

    # Ensure columns are vector(1024)
    execute "ALTER TABLE pages ALTER COLUMN embedding TYPE vector(1024);"
    execute "ALTER TABLE chunks ALTER COLUMN embedding TYPE vector(1024);"

    # Recreate HNSW indexes
    execute """
    CREATE INDEX CONCURRENTLY pages_embedding_idx
    ON pages USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
    """

    execute """
    CREATE INDEX CONCURRENTLY chunks_embedding_idx
    ON chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
    """
  end

  def down do
    # Nothing to reverse — embeddings need regeneration regardless
    :ok
  end
end
