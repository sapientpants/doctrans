defmodule Doctrans.Config.Uploads do
  @moduledoc """
  Typed access to the storage root and per-file size limit.

  `upload_dir/0` is the single storage root: writers resolve document, run, and
  page paths beneath it, and the endpoint serves generated page images from it.
  It is resolved on every call so a release reads its own runtime location
  rather than a path baked in at build time. Leaving `:upload_dir` unset selects
  `priv/static/uploads` inside the running application; `DOCTRANS_DATA_DIR`
  replaces it, and `config/runtime.exs` owns that variable's validation.
  """

  alias Doctrans.Config

  @default_dir "priv/static/uploads"

  @doc """
  Returns the storage root for uploads and generated files.

  A configured path is expanded, so every caller can rely on an absolute root:
  page paths are persisted relative to it (`Doctrans.Processing.Extraction`),
  and a relative root would resolve them against the working directory instead.
  """
  @spec upload_dir() :: String.t()
  def upload_dir do
    case Config.get(:uploads, :upload_dir) do
      nil ->
        default_dir()

      dir when is_binary(dir) ->
        Path.expand(dir)

      other ->
        raise ArgumentError,
              "invalid :upload_dir for :uploads: expected a path string or no value " <>
                "(for #{@default_dir} inside the application), got: #{inspect(other)}"
    end
  end

  @doc """
  Returns the storage root, raising when it is unsafe to use.

  Two misconfigurations are refused at startup rather than discovered later:

  - The endpoint serves `priv/static` at `/` for the paths in
    `DoctransWeb.static_paths/0`, ahead of the page-image allow-list. A storage
    root placed under one of those directories would hand out retained sources
    and converted PDFs as ordinary static assets.
  - `Doctrans.Documents.Sweeper` deletes directories under `<root>/documents`
    that no database row owns. A root that is not dedicated to Doctrans — a home
    directory, where `documents/` and `Documents/` are one folder on macOS, or a
    share that already has a `documents/` tree — would have its own folders
    swept as orphans. A nondefault root whose `documents/` directory already
    holds subdirectories that are not named by a document id is therefore
    rejected before anything can run against it. The default root lives inside
    the application directory, which nothing else writes to, so it is not
    checked.
  """
  # The path is the configured storage root; no request value contributes to it.
  # sobelow_skip ["Traversal.FileModule"]
  @spec validate_root!() :: String.t()
  def validate_root! do
    dir = upload_dir()

    if served_statically?(dir) do
      raise ArgumentError,
            "the storage root #{dir} is inside the statically served directory and " <>
              "would expose retained sources over HTTP; point DOCTRANS_DATA_DIR outside " <>
              "#{Enum.join(static_roots(), " and ")}"
    end

    case foreign_document_dirs(dir) do
      [] ->
        dir

      foreign ->
        raise ArgumentError,
              "the storage root #{dir} is not dedicated to Doctrans: #{dir}/documents " <>
                "already contains #{Enum.map_join(foreign, ", ", &inspect/1)}, " <>
                "which no document owns. The sweeper deletes unowned directories " <>
                "under documents/, so point DOCTRANS_DATA_DIR at an empty directory " <>
                "or one only this application writes to."
    end
  end

  @doc """
  Creates the storage root if it does not exist yet, and returns it.

  A nondefault `DOCTRANS_DATA_DIR` normally points at an empty volume, so the
  root is created at startup: uploads create their own subdirectories, but the
  filesystem health check probes the root itself and would otherwise report a
  missing directory until the first document arrived.

  Failure names the setting to correct: this runs from `Doctrans.Application`
  before the supervision tree starts, where a bare filesystem error would reach
  the operator as an unexplained boot crash.
  """
  # The path is the configured storage root; no request value contributes to it.
  # sobelow_skip ["Traversal.FileModule"]
  @spec ensure_root!() :: String.t()
  def ensure_root! do
    dir = upload_dir()

    case File.mkdir_p(dir) do
      :ok ->
        dir

      {:error, reason} ->
        raise "could not create the storage root #{dir}: #{:file.format_error(reason)}. " <>
                "Set DOCTRANS_DATA_DIR to a directory the application can write, " <>
                "or unset it to use the default inside the application directory."
    end
  end

  @spec max_file_size() :: pos_integer()
  def max_file_size, do: Config.fetch!(:uploads, :max_file_size)

  defp default_dir, do: Application.app_dir(:doctrans, @default_dir)

  # Subdirectories of `<root>/documents` whose names are not document ids, for
  # a nondefault root. Loose files (`.DS_Store`) are not listed: the sweeper
  # removes directories only, so a file never becomes collateral.
  #
  # The directory name and the id shape mirror `Doctrans.Documents.Layout`
  # (`documents_dir/0`, `document_dir_name?/1`), which builds its paths on this
  # module's root and so cannot be called from here without a dependency cycle.
  defp foreign_document_dirs(dir) do
    if dir == default_dir(), do: [], else: foreign_entries(Path.join(dir, "documents"))
  end

  defp foreign_entries(documents_dir) do
    case File.ls(documents_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name ->
          not Uniq.UUID.valid?(name) and File.dir?(Path.join(documents_dir, name))
        end)
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp served_statically?(dir) do
    roots = static_roots()

    Enum.any?(roots, &inside?(dir, &1)) and
      not Enum.any?(roots, &inside?(dir, Path.join(&1, "uploads")))
  end

  # In development `priv` is a symlink into the source tree, so the same
  # directory is reachable under two names; both have to be rejected.
  defp static_roots do
    priv = Application.app_dir(:doctrans, "priv")

    linked =
      case :file.read_link(priv) do
        {:ok, target} -> [Path.expand(List.to_string(target), Path.dirname(priv))]
        {:error, _reason} -> []
      end

    Enum.map([priv | linked], &Path.join(&1, "static"))
  end

  defp inside?(dir, base), do: dir == base or String.starts_with?(dir, base <> "/")
end
