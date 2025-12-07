defmodule Doctrans.Repo.Migrations.AddFulltextSearch do
  use Ecto.Migration

  def up do
    # Add tsvector columns for full-text search
    alter table(:pages) do
      add :original_searchable, :tsvector
      add :translated_searchable, :tsvector
    end

    # Create GIN indexes for fast full-text search
    # Note: For large production databases, consider creating these indexes
    # CONCURRENTLY in a separate migration to avoid blocking writes.
    # This requires @disable_ddl_transaction and @disable_migration_lock.
    create index(:pages, [:original_searchable],
             using: :gin,
             name: :pages_original_searchable_idx
           )

    create index(:pages, [:translated_searchable],
             using: :gin,
             name: :pages_translated_searchable_idx
           )

    # Helper function: map app language code to PostgreSQL text search config
    execute """
    CREATE OR REPLACE FUNCTION get_fts_config(lang text) RETURNS regconfig AS $$
    BEGIN
      RETURN CASE lang
        WHEN 'da' THEN 'danish'::regconfig
        WHEN 'de' THEN 'german'::regconfig
        WHEN 'en' THEN 'english'::regconfig
        WHEN 'es' THEN 'spanish'::regconfig
        WHEN 'fr' THEN 'french'::regconfig
        WHEN 'it' THEN 'italian'::regconfig
        WHEN 'nl' THEN 'dutch'::regconfig
        WHEN 'no' THEN 'norwegian'::regconfig
        WHEN 'pt' THEN 'portuguese'::regconfig
        WHEN 'sv' THEN 'swedish'::regconfig
        ELSE 'simple'::regconfig
      END;
    END;
    $$ LANGUAGE plpgsql IMMUTABLE;
    """

    # Trigger function: auto-update tsvector columns on INSERT/UPDATE
    execute """
    CREATE OR REPLACE FUNCTION pages_searchable_trigger() RETURNS trigger AS $$
    DECLARE
      target_lang text;
    BEGIN
      -- Get target language from parent document
      SELECT d.target_language INTO target_lang
      FROM documents d WHERE d.id = NEW.document_id;

      -- Original: always 'simple' (source language varies)
      NEW.original_searchable := to_tsvector('simple', COALESCE(NEW.original_markdown, ''));

      -- Translated: use language-specific config
      NEW.translated_searchable := to_tsvector(
        get_fts_config(COALESCE(target_lang, 'en')),
        COALESCE(NEW.translated_markdown, '')
      );

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Create trigger for INSERT and UPDATE of markdown columns
    execute """
    CREATE TRIGGER pages_searchable_update
      BEFORE INSERT OR UPDATE OF original_markdown, translated_markdown
      ON pages
      FOR EACH ROW
      EXECUTE FUNCTION pages_searchable_trigger();
    """

    # Backfill existing data
    execute """
    UPDATE pages p SET
      original_searchable = to_tsvector('simple', COALESCE(p.original_markdown, '')),
      translated_searchable = to_tsvector(
        get_fts_config(COALESCE(d.target_language, 'en')),
        COALESCE(p.translated_markdown, '')
      )
    FROM documents d
    WHERE p.document_id = d.id
      AND (p.original_markdown IS NOT NULL OR p.translated_markdown IS NOT NULL);
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS pages_searchable_update ON pages"
    execute "DROP FUNCTION IF EXISTS pages_searchable_trigger()"
    execute "DROP FUNCTION IF EXISTS get_fts_config(text)"

    drop index(:pages, [:original_searchable], name: :pages_original_searchable_idx)
    drop index(:pages, [:translated_searchable], name: :pages_translated_searchable_idx)

    alter table(:pages) do
      remove :original_searchable
      remove :translated_searchable
    end
  end
end
