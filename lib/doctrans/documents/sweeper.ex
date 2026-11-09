defmodule Doctrans.Documents.Sweeper do
  @moduledoc """
  Cleans up orphaned document directories from the uploads folder.

  A directory is considered orphaned when:
  - Its name has the shape of a document id (`Doctrans.Documents.Layout.document_dir_name?/1`)
  - It is older than a configurable threshold (default: 24 hours)
  - There is no document with that ID in the database

  The shape check comes first on purpose. Every directory the layout writes
  under `documents/` is named by a document id, so a directory named anything
  else is a foreign entry: this application did not create it, and it is never
  a candidate. Without that gate a storage root shared with other data (a home
  directory whose `Documents` folder is this one on a case-insensitive
  filesystem, a NAS share with its own `documents/`) would have every old
  subfolder deleted as an "orphan" within a minute of boot. A foreign directory
  is logged and left alone on every sweep, and `validate_root!/0` refuses at
  boot a root that already holds one.

  This handles cases where:
  - Upload was started but never completed
  - Database deletion succeeded but file deletion failed
  - Application crashed during document processing
  """

  require Logger

  import Ecto.Query

  alias Doctrans.Config.Uploads
  alias Doctrans.Documents.{Document, Layout}
  alias Doctrans.Repo

  @default_grace_period_hours 24

  @doc """
  Returns the storage root, raising when it is not dedicated to Doctrans.

  A sweep deletes directories under `documents/` that no row owns, so a root
  that already holds foreign directories — a home directory, where `documents/`
  and `Documents/` are one folder on macOS, or a share with a `documents/` tree
  of its own — would have them removed a minute after boot. Such a root is
  refused from `Doctrans.Application` before the supervision tree starts. The
  default root lives inside the application directory, which nothing else
  writes to, so it is not checked.
  """
  @spec validate_root!() :: String.t()
  def validate_root! do
    root = Layout.root()
    foreign = if Uploads.default_root?(), do: [], else: foreign_directories()

    case foreign do
      [] ->
        root

      names ->
        raise ArgumentError,
              "the storage root #{root} is not dedicated to Doctrans: " <>
                "#{Layout.documents_dir()} already contains " <>
                "#{Enum.map_join(names, ", ", &inspect/1)}, which no document owns. " <>
                "The sweeper deletes unowned directories under documents/, so point " <>
                "DOCTRANS_DATA_DIR at an empty directory or one only this application " <>
                "writes to."
    end
  end

  @doc """
  The foreign directories under `documents/`: its subdirectories that are not
  named by a document id, sorted by name.

  Loose files (`.DS_Store`) are not among them. A sweep removes directories
  only, so a file is never collateral and does not make a root shared.
  """
  @spec foreign_directories() :: [String.t()]
  def foreign_directories do
    case subdirectories(Layout.documents_dir()) do
      {:ok, {_document_dirs, foreign}} -> foreign
      {:error, _reason} -> []
    end
  end

  @doc """
  Finds document directories that are orphaned (old and no matching DB record).

  ## Options

  - `:grace_period_hours` - Only consider directories older than this (default: 24)

  Returns a list of directory paths that are orphaned.
  """
  @spec find_orphaned_directories(keyword()) :: [String.t()]
  def find_orphaned_directories(opts \\ []) do
    grace_period_hours = Keyword.get(opts, :grace_period_hours, @default_grace_period_hours)
    documents_dir = Layout.documents_dir()

    case subdirectories(documents_dir) do
      {:ok, {document_dirs, foreign}} ->
        # Reported, so an operator who pointed the storage root at a shared
        # directory sees what the sweeper is stepping around.
        Enum.each(foreign, &Logger.warning("Sweeper: skipping foreign directory #{inspect(&1)}"))

        valid_ids = get_valid_document_ids()
        cutoff = DateTime.utc_now() |> DateTime.add(-grace_period_hours, :hour)

        document_dirs
        |> Enum.filter(&orphaned?(&1, valid_ids, documents_dir, cutoff))
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

  Returns `{:ok, deleted_count}` when every orphan was removed (or, in a dry
  run, counted). A directory that could not be removed is reported rather than
  only logged: `{:error, {:sweep_incomplete, [deleted: count, failed: paths]}}`
  names the orphans still on disk, so a directory that can never be deleted
  stays visible to whoever reads the result, sweep after sweep.
  """
  @spec sweep(keyword()) :: {:ok, non_neg_integer()} | {:error, Doctrans.Errors.reason()}
  def sweep(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    orphaned = find_orphaned_directories(opts)

    if Enum.empty?(orphaned) do
      Logger.info("No orphaned directories found")
      {:ok, 0}
    else
      Logger.info("Found #{length(orphaned)} orphaned directories")

      {deleted, failed} = Enum.split_with(orphaned, &delete_directory(&1, dry_run))

      case failed do
        [] -> {:ok, length(deleted)}
        failed -> {:error, {:sweep_incomplete, [deleted: length(deleted), failed: failed]}}
      end
    end
  end

  # Paths are direct File.ls children of the configured documents directory; rm_rf does not follow symlinks.
  # sobelow_skip ["Traversal.FileModule"]
  defp delete_directory(path, dry_run) do
    if dry_run do
      Logger.info("[DRY RUN] Would delete: #{path}")
      true
    else
      case File.rm_rf(path) do
        {:ok, _} ->
          Logger.info("Deleted orphaned directory: #{path}")
          true

        {:error, reason, file} ->
          Logger.error(
            "Failed to delete orphaned directory #{path} at #{file}: #{inspect(reason)}"
          )

          false
      end
    end
  end

  defp get_valid_document_ids do
    Document
    |> select([d], d.id)
    |> Repo.all()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  # The subdirectories of `documents_dir`, sorted and split into those named by
  # a document id and the foreign ones. Files are dropped here, so they are
  # neither candidates nor reported.
  @spec subdirectories(String.t()) ::
          {:ok, {[String.t()], [String.t()]}} | {:error, File.posix()}
  defp subdirectories(documents_dir) do
    with {:ok, entries} <- File.ls(documents_dir) do
      split =
        entries
        |> Enum.filter(&directory?(documents_dir, &1))
        |> Enum.sort()
        |> Enum.split_with(&Layout.document_dir_name?/1)

      {:ok, split}
    end
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
