defmodule Doctrans.Config.Uploads do
  @moduledoc "Typed access to the upload directory and per-file size limit."

  alias Doctrans.Config

  @spec upload_dir() :: String.t()
  def upload_dir, do: Config.fetch!(:uploads, :upload_dir)

  @spec max_file_size() :: pos_integer()
  def max_file_size, do: Config.fetch!(:uploads, :max_file_size)
end
