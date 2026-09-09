defmodule Doctrans.Repo.Migrations.TrackPageContentRevisions do
  use Ecto.Migration

  def up do
    alter table(:pages) do
      add :content_revision, :bigint, null: false, default: 0
    end

    # Keep invalidation atomic even for bulk updates or callers holding old structs.
    execute """
    CREATE FUNCTION invalidate_page_embeddings() RETURNS trigger AS $$
    BEGIN
      IF NEW.original_markdown IS DISTINCT FROM OLD.original_markdown
         OR (NEW.extraction_status IS DISTINCT FROM OLD.extraction_status
             AND NEW.extraction_status <> 'completed') THEN
        NEW.content_revision := OLD.content_revision + 1;
        NEW.embedding := NULL;
        NEW.embedding_status := 'pending';
        DELETE FROM chunks WHERE page_id = OLD.id;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER pages_invalidate_embeddings
    BEFORE UPDATE ON pages
    FOR EACH ROW EXECUTE FUNCTION invalidate_page_embeddings();
    """
  end

  def down do
    execute "DROP TRIGGER pages_invalidate_embeddings ON pages"
    execute "DROP FUNCTION invalidate_page_embeddings()"

    alter table(:pages) do
      remove :content_revision
    end
  end
end
