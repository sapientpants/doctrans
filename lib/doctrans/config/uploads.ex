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
  page paths are persisted relative to it (`Doctrans.Processing.PdfProcessor`),
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
  Returns the storage root, raising when static serving would expose it.

  The endpoint serves `priv/static` at `/` for the paths in
  `DoctransWeb.static_paths/0`, ahead of the page-image allow-list. A storage
  root placed under one of those directories would hand out retained sources and
  converted PDFs as ordinary static assets, so it is rejected at startup rather
  than discovered from an exposed document.
  """
  @spec validate_root!() :: String.t()
  def validate_root! do
    dir = upload_dir()

    if served_statically?(dir) do
      raise ArgumentError,
            "the storage root #{dir} is inside the statically served directory and " <>
              "would expose retained sources over HTTP; point DOCTRANS_DATA_DIR outside " <>
              "#{Enum.join(static_roots(), " and ")}"
    end

    dir
  end

  @spec max_file_size() :: pos_integer()
  def max_file_size, do: Config.fetch!(:uploads, :max_file_size)

  defp default_dir, do: Application.app_dir(:doctrans, @default_dir)

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
