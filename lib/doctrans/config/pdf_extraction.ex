defmodule Doctrans.Config.PdfExtraction do
  @moduledoc """
  Typed access to the PDF extraction bounds.

  Every bound a document can exhaust lives here, so the defaults are stated once
  rather than restated by each caller. See `config/config.exs` for what each one
  is for.
  """

  alias Doctrans.Config

  @default_dpi 150
  @default_timeout 120_000
  @default_info_timeout 15_000
  @default_job_timeout 3_600_000
  @default_max_pages 1_000
  @default_max_image_bytes 20_000_000
  @default_max_page_pixels 40_000_000

  # Fallbacks for a daemon started with a slim PATH, mirroring the converter's
  # `:search_paths`: a Homebrew poppler is found the same way a Homebrew
  # LibreOffice is. Configurable so a deployment can pin or disable them.
  @default_search_dirs ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

  @doc "Render resolution in DPI."
  @spec dpi() :: pos_integer()
  def dpi, do: setting(:dpi, @default_dpi)

  @doc "Milliseconds one `pdftoppm` render may take."
  @spec timeout() :: pos_integer()
  def timeout, do: setting(:timeout, @default_timeout)

  @doc "Milliseconds one `pdfinfo` call may take."
  @spec info_timeout() :: pos_integer()
  def info_timeout, do: setting(:info_timeout, @default_info_timeout)

  @doc "Milliseconds the whole extraction job may take."
  @spec job_timeout() :: pos_integer()
  def job_timeout, do: setting(:job_timeout, @default_job_timeout)

  @doc "Pages above which a document is rejected before any page is rendered."
  @spec max_pages() :: pos_integer()
  def max_pages, do: setting(:max_pages, @default_max_pages)

  @doc "Bytes above which a rendered page image is rejected and deleted."
  @spec max_image_bytes() :: pos_integer()
  def max_image_bytes, do: setting(:max_image_bytes, @default_max_image_bytes)

  @doc "Pixels a page may rasterize to at the configured DPI before it is rejected."
  @spec max_page_pixels() :: pos_integer()
  def max_page_pixels, do: setting(:max_page_pixels, @default_max_page_pixels)

  @doc "Directories to search for a poppler executable when `PATH` has no match."
  @spec search_dirs() :: [String.t()]
  def search_dirs, do: setting(:search_dirs, @default_search_dirs)

  @doc "An explicit path to a poppler executable, or `nil` to resolve it normally."
  @spec executable_path(:pdftoppm_path | :pdfinfo_path) :: String.t() | nil
  def executable_path(key) when key in [:pdftoppm_path, :pdfinfo_path],
    do: setting(key, nil)

  defp setting(key, default) do
    case Config.get(:pdf_extraction, key) do
      nil -> default
      value -> value
    end
  end
end
