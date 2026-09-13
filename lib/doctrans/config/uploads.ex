defmodule Doctrans.Config.Uploads do
  @moduledoc """
  Typed access to the storage root and per-file size limit.

  `upload_dir/0` is the single storage root: writers resolve document, run, and
  page paths beneath it, and the endpoint serves generated page images from it.
  It is resolved on every call so a release reads its own runtime location
  rather than a path baked in at build time.
  """

  alias Doctrans.Config

  @default_dir "priv/static/uploads"

  @doc """
  Returns the storage root for uploads and generated files.

  The configured `:default` resolves to `priv/static/uploads` inside the running
  application; `DOCTRANS_DATA_DIR` (see `config/runtime.exs`) replaces it with an
  absolute path.
  """
  @spec upload_dir() :: String.t()
  def upload_dir do
    case Config.fetch!(:uploads, :upload_dir) do
      :default -> Application.app_dir(:doctrans, @default_dir)
      dir when is_binary(dir) -> dir
    end
  end

  @spec max_file_size() :: pos_integer()
  def max_file_size, do: Config.fetch!(:uploads, :max_file_size)
end
