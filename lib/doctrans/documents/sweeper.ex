defmodule Doctrans.Documents.Sweeper do
  @moduledoc """
  Cleans up orphaned document files from the uploads directory.

  Orphaned files can occur when:
  - Database deletion succeeds but file deletion fails
  - Application crashes during document deletion
  - Manual database manipulation

  This module provides functions to identify and remove document directories
  that no longer have corresponding database records.
  """

  require Logger

  import Ecto.Query

  alias Doctrans.Documents
  alias Doctrans.Documents.Document
  alias Doctrans.Repo

  @doc """
  Finds document directories that don't have corresponding database records.

  Returns a list of directory paths that are orphaned.
  """
  def find_orphaned_directories do
    uploads_dir = Documents.uploads_dir()
    documents_dir = Path.join(uploads_dir, "documents")

    case File.ls(documents_dir) do
      {:ok, entries} ->
        valid_ids = get_valid_document_ids()

        entries
        |> Enum.filter(&(directory?(documents_dir, &1) && &1 not in valid_ids))
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
  Finds documents that have been stuck in a transient status for too long.

  These are documents that may have failed during upload or processing
  and were never cleaned up.

  ## Options

  - `:max_age_hours` - Documents older than this in hours are considered stale (default: 24)
  - `:statuses` - List of statuses to check (default: ["uploading", "extracting"])
  """
  def find_stale_documents(opts \\ []) do
    max_age_hours = Keyword.get(opts, :max_age_hours, 24)
    statuses = Keyword.get(opts, :statuses, ["uploading", "extracting"])

    cutoff = DateTime.utc_now() |> DateTime.add(-max_age_hours, :hour)

    Document
    |> where([d], d.status in ^statuses)
    |> where([d], d.inserted_at < ^cutoff)
    |> Repo.all()
  end

  @doc """
  Removes orphaned directories from the filesystem.

  ## Options

  - `:dry_run` - If true, only logs what would be deleted without actually deleting (default: false)

  Returns `{:ok, deleted_count}` or `{:error, reason}`.
  """
  def sweep_orphaned_directories(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    orphaned = find_orphaned_directories()

    if Enum.empty?(orphaned) do
      Logger.info("No orphaned directories found")
      {:ok, 0}
    else
      Logger.info("Found #{length(orphaned)} orphaned directories")

      deleted_count = Enum.reduce(orphaned, 0, &delete_orphaned_directory(&1, &2, dry_run))

      {:ok, deleted_count}
    end
  end

  defp delete_orphaned_directory(path, count, dry_run) do
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

  @doc """
  Removes stale documents from the database and filesystem.

  ## Options

  - `:dry_run` - If true, only logs what would be deleted (default: false)
  - `:max_age_hours` - Documents older than this are considered stale (default: 24)
  - `:statuses` - List of statuses to check (default: ["uploading", "extracting"])

  Returns `{:ok, deleted_count}` or `{:error, reason}`.
  """
  def sweep_stale_documents(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    stale = find_stale_documents(opts)

    if Enum.empty?(stale) do
      Logger.info("No stale documents found")
      {:ok, 0}
    else
      Logger.info("Found #{length(stale)} stale documents")

      deleted_count = Enum.reduce(stale, 0, &delete_stale_document(&1, &2, dry_run))

      {:ok, deleted_count}
    end
  end

  defp delete_stale_document(document, count, dry_run) do
    if dry_run do
      Logger.info("[DRY RUN] Would delete stale document: #{document.id} (#{document.title})")
      count + 1
    else
      case Documents.delete_document(document) do
        {:ok, _} ->
          Logger.info("Deleted stale document: #{document.id} (#{document.title})")
          count + 1

        {:error, reason} ->
          Logger.error("Failed to delete document #{document.id}: #{inspect(reason)}")
          count
      end
    end
  end

  @doc """
  Runs a full sweep of both orphaned directories and stale documents.

  ## Options

  - `:dry_run` - If true, only logs what would be deleted (default: false)
  - `:max_age_hours` - For stale documents (default: 24)
  - `:statuses` - For stale documents (default: ["uploading", "extracting"])

  Returns a map with results:
  ```
  %{
    orphaned_directories: {:ok, count},
    stale_documents: {:ok, count}
  }
  ```
  """
  def sweep_all(opts \\ []) do
    Logger.info("Starting document sweep...")

    orphaned_result = sweep_orphaned_directories(opts)
    stale_result = sweep_stale_documents(opts)

    Logger.info("Document sweep complete")

    %{
      orphaned_directories: orphaned_result,
      stale_documents: stale_result
    }
  end

  # Private functions

  defp get_valid_document_ids do
    Document
    |> select([d], type(d.id, :string))
    |> Repo.all()
    |> MapSet.new()
  end

  defp directory?(base_path, name) do
    Path.join(base_path, name) |> File.dir?()
  end
end
