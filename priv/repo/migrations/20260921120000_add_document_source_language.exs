defmodule Doctrans.Repo.Migrations.AddDocumentSourceLanguage do
  use Ecto.Migration

  # Each document now carries its own source language instead of the app-wide
  # `config :doctrans, :defaults, source_language: ...`.
  #
  # Documents processed before this column existed were translated with whatever
  # that configured default said at the time, so the backfill reads it rather
  # than hardcoding "de" — hardcoding would relabel every old document on a
  # deployment that had changed the default.
  #
  # The configured value is guarded against the allowlist below before it reaches
  # the SQL string, so what is interpolated is always one of a fixed known-safe
  # set. The list is a frozen copy of `Doctrans.Languages.supported/0` as of this
  # migration and is deliberately *not* read from that module: a migration must
  # keep behaving the same forever, while the module's list is free to change.
  @supported ~w(da de en es fr it nl no pl pt sv)
  @fallback "de"

  def up do
    alter table(:documents) do
      add :source_language, :string
    end

    flush()

    execute """
    UPDATE documents
    SET source_language = '#{default_source_language()}'
    WHERE source_language IS NULL;
    """

    alter table(:documents) do
      modify :source_language, :string, null: false
    end
  end

  def down do
    alter table(:documents) do
      remove :source_language
    end
  end

  defp default_source_language do
    configured = Application.get_env(:doctrans, :defaults, [])[:source_language]

    if configured in @supported, do: configured, else: @fallback
  end
end
