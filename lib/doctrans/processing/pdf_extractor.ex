defmodule Doctrans.Processing.PdfExtractor do
  @moduledoc """
  Extracts page images from PDF files using pdftoppm (poppler-utils).

  Requires `poppler` to be installed:
  - macOS: `brew install poppler`
  - Ubuntu/Debian: `apt-get install poppler-utils`
  """

  @behaviour Doctrans.Processing.PdfExtractorBehaviour

  require Logger

  use Gettext, backend: DoctransWeb.Gettext

  @doc """
  Extracts all pages from a PDF file as PNG images.

  Returns `{:ok, page_count}` on success or `{:error, reason}` on failure.

  ## Options

  - `:dpi` - Resolution in DPI (default: from config, fallback 200)
  """
  def extract_pages(pdf_path, output_dir, opts \\ []) do
    default_dpi = get_in(Application.get_env(:doctrans, :pdf_extraction, []), [:dpi]) || 200
    dpi = Keyword.get(opts, :dpi, default_dpi)

    # Ensure output directory exists
    File.mkdir_p!(output_dir)

    # Build the pdftoppm command
    output_prefix = Path.join(output_dir, "page")

    args = [
      "-png",
      "-r",
      to_string(dpi),
      pdf_path,
      output_prefix
    ]

    Logger.info("Extracting pages from #{pdf_path} to #{output_dir}")

    # Preserve PATH for command lookup, but clear other potentially sensitive env vars
    case System.cmd("pdftoppm", args,
           stderr_to_stdout: true,
           env: [{"PATH", System.get_env("PATH")}]
         ) do
      {_output, 0} ->
        # Count the generated files
        page_count = count_pages(output_dir)
        Logger.info("Successfully extracted #{page_count} pages")
        {:ok, page_count}

      {error_output, exit_code} ->
        Logger.error("pdftoppm failed with exit code #{exit_code}: #{error_output}")

        {:error,
         dgettext("errors", "PDF extraction failed: %{error}", error: String.trim(error_output))}
    end
  end

  @doc """
  Gets the number of pages in a PDF without extracting.
  """
  def get_page_count(pdf_path) do
    # Preserve PATH for command lookup, but clear other potentially sensitive env vars
    case System.cmd("pdfinfo", [pdf_path],
           stderr_to_stdout: true,
           env: [{"PATH", System.get_env("PATH")}]
         ) do
      {output, 0} ->
        case Regex.run(~r/Pages:\s*(\d+)/, output) do
          [_, count] -> {:ok, String.to_integer(count)}
          _ -> {:error, dgettext("errors", "Could not parse page count from pdfinfo output")}
        end

      {error_output, _exit_code} ->
        {:error, dgettext("errors", "pdfinfo failed: %{error}", error: String.trim(error_output))}
    end
  end

  @doc """
  Returns the path to a specific page image.

  Page numbers are 1-indexed.
  """
  def page_image_path(output_dir, page_number) do
    # pdftoppm generates files like page-01.png, page-02.png, etc.
    # The number of digits depends on the total page count
    pattern = Path.join(output_dir, "page-*.png")

    pattern
    |> Path.wildcard()
    |> Enum.find(&(extract_page_number(&1) == page_number))
  end

  @doc """
  Lists all page image paths in order.
  """
  def list_page_images(output_dir) do
    pattern = Path.join(output_dir, "page-*.png")

    pattern
    |> Path.wildcard()
    |> Enum.sort_by(&extract_page_number/1)
  end

  @doc """
  Checks if pdftoppm is available on the system.
  """
  def available? do
    case System.find_executable("pdftoppm") do
      nil -> false
      _ -> true
    end
  end

  # Private functions

  defp count_pages(output_dir) do
    output_dir
    |> list_page_images()
    |> length()
  end

  defp extract_page_number(file_path) do
    file_path
    |> Path.basename(".png")
    |> String.replace(~r/^page-0*/, "")
    |> String.to_integer()
  end
end
