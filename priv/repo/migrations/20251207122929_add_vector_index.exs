defmodule Doctrans.Repo.Migrations.AddVectorIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # HNSW index for fast approximate nearest neighbor search on embeddings
    # Using cosine distance operator (vector_cosine_ops) to match search queries
    # CONCURRENTLY allows the index to be built without blocking writes
    #
    # Parameters:
    # - m: max connections per node (default 16, higher = better recall, more memory)
    # - ef_construction: size of candidate list during construction (default 64)
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS pages_embedding_idx
    ON pages USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS pages_embedding_idx;"
  end
end
