defmodule Doctrans.Documents.Sweeper do
  @moduledoc """
  Cleans up orphaned document directories from the uploads folder.

  A directory is considered orphaned when:
  - It is older than a configurable threshold (default: 24 hours)
  - There is no document with that ID in the database

  This handles cases where:
  - Upload was started but never completed
  - Database deletion succeeded but file deletion failed
  - Application crashed during document processing
  """

  require Logger

  import Ecto.Query

  alias Doctrans.Documents
  alias Doctrans.Documents.Document
  alias Doctrans.Repo

  @default_grace_period_hours 24

  @doc """
  Finds document directories that are orphaned (old and no matching DB record).

  ## Options

  - `:grace_period_hours` - Only consider directories older than this (default: 24)

  Returns a list of directory paths that are orphaned.
  """
  def find_orphaned_directories(opts \\ []) do
    grace_period_hours = Keyword.get(opts, :grace_period_hours, @default_grace_period_hours)
    uploads_dir = Documents.uploads_dir()
    documents_dir = Path.join(uploads_dir, "documents")

    case File.ls(documents_dir) do
      {:ok, entries} ->
        valid_ids = get_valid_document_ids()
        cutoff = DateTime.utc_now() |> DateTime.add(-grace_period_hours, :hour)

        entries
        |> Enum.filter(
          &(directory?(documents_dir, &1) && orphaned?(&1, valid_ids, documents_dir, cutoff))
        )
        |> Enum.map(&Path.join(documents_dir, &1))

      {:error, :enoent} ->
        Logger.info("Documents directory does not exist: #{documents_dir}")
        []

      {:error, reason} ->
        Logger.error("Failed to list documents directory: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Removes orphaned directories from the filesystem.

  ## Options

  - `:dry_run` - If true, only logs what would be deleted (default: false)
  - `:grace_period_hours` - Only delete directories older than this (default: 24)

  Returns `{:ok, deleted_count}`.
  """
  def sweep(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    orphaned = find_orphaned_directories(opts)

    if Enum.empty?(orphaned) do
      Logger.info("No orphaned directories found")
      {:ok, 0}
    else
      Logger.info("Found #{length(orphaned)} orphaned directories")

      deleted_count = Enum.reduce(orphaned, 0, &delete_directory(&1, &2, dry_run))

      {:ok, deleted_count}
    end
  end

  defp delete_directory(path, count, dry_run) do
    if dry_run do
      Logger.info("[DRY RUN] Would delete: #{path}")
      count + 1
    else
      case File.rm_rf(path) do
        {:ok, _} ->
          Logger.info("Deleted orphaned directory: #{path}")
          count + 1

        {:error, reason, file} ->
          Logger.error("Failed to delete #{file}: #{inspect(reason)}")
          count
      end
    end
  end

  defp get_valid_document_ids do
    Document
    |> select([d], type(d.id, :string))
    |> Repo.all()
    |> MapSet.new()
  end

  defp directory?(base_path, name) do
    Path.join(base_path, name) |> File.dir?()
  end

  defp orphaned?(dir_name, valid_ids, documents_dir, cutoff) do
    # Not in database and old enough
    !MapSet.member?(valid_ids, dir_name) &&
      directory_older_than?(documents_dir, dir_name, cutoff)
  end

  defp directory_older_than?(base_path, name, cutoff) do
    path = Path.join(base_path, name)

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        dir_time = DateTime.from_unix!(mtime)
        DateTime.compare(dir_time, cutoff) == :lt

      {:error, _} ->
        false
    end
  end
end
