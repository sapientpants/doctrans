defmodule Doctrans.Repo.Migrations.UpdatePgvectorExtension do
  use Ecto.Migration

  # A newer image ships a newer `vector` library, but a database keeps the
  # extension version it was created with until it is updated explicitly. This
  # brings existing databases up to whatever the pinned image provides (#315).
  def up do
    execute "ALTER EXTENSION vector UPDATE"
  end

  # Extension updates are one-way: pgvector ships no downgrade scripts.
  def down, do: :ok
end
