defmodule Doctrans.Processing.PdfExtractor do
  @moduledoc """
  Extracts page images from PDF files using pdftoppm (poppler-utils).

  Requires `poppler` to be installed:
  - macOS: `brew install poppler`
  - Ubuntu/Debian: `apt-get install poppler-utils`

  Every `pdfinfo` and `pdftoppm` run goes through `Doctrans.Processing.Subprocess`,
  so it carries a deadline, keeps only the tail of its diagnostic output, and has
  its process group killed on the way out. Extraction runs in a single-slot queue:
  without a deadline one malformed page holds that slot for as long as the renderer
  cares to spin, and no other document can be extracted meanwhile.

  Four limits bound the work a single document can ask for, all configurable under
  `:pdf_extraction` and read through `Doctrans.Config.PdfExtraction`:

  - `:max_pages` rejects a document before any page is rendered
  - `:max_page_pixels` rejects a page whose *geometry* would rasterize to more
    pixels than that at the configured `:dpi`. This is the bound that has to come
    first: a page with a maximal PDF MediaBox renders to gigabytes of memory and
    disk well inside any sane deadline, so catching it afterwards is too late.
  - `:max_image_bytes` rejects a rendered page too large to be worth sending to a
    model, and deletes it
  - `:timeout` bounds one render, and a `:deadline` passed by the caller bounds
    the document as a whole, so per-page bounds cannot add up past the job that
    contains them

  Each reports the value and the limit, so the answer is either a smaller
  document or a lower `:dpi`.
  """

  @behaviour Doctrans.Processing.PdfExtractorBehaviour

  require Logger

  alias Doctrans.Config.PdfExtraction
  alias Doctrans.Processing.Executable
  alias Doctrans.Processing.Subprocess

  # PDF user-space units are 1/72 inch.
  @points_per_inch 72

  @doc """
  Extracts all pages from a PDF file as PNG images.

  Returns `{:ok, page_count}` on success or `{:error, reason}` on failure.

  `get_page_count/1` establishes how many pages there are and rejects a document
  that is too long or whose pages are too large; the render then gets the per-page
  timeout for each page, capped by the document budget.

  ## Options

  - `:dpi` - Resolution in DPI (default: from config)
  - `:deadline` - a `System.monotonic_time(:millisecond)` value the whole
    extraction must finish by
  """
  # output_dir is the generated document UUID/pages directory supplied by PdfProcessor.
  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def extract_pages(pdf_path, output_dir, opts \\ []) do
    with {:ok, page_count} <- get_page_count(pdf_path),
         {:ok, timeout} <- budget(opts, document_ceiling(page_count)) do
      File.mkdir_p!(output_dir)

      args = render_args(pdf_path, output_dir, opts)

      Logger.info("Extracting pages from #{pdf_path} to #{output_dir}")

      with {:ok, _output} <- render(args, timeout),
           :ok <- check_image_sizes(output_dir) do
        extracted = output_dir |> list_page_images() |> length()
        Logger.info("Successfully extracted #{extracted} pages")
        {:ok, extracted}
      end
    end
  end

  @doc """
  Extracts a single page from a PDF file as a PNG image.

  Returns `{:ok, image_path}` on success or `{:error, reason}` on failure.

  ## Options

  - `:dpi` - Resolution in DPI (default: from config)
  - `:deadline` - a `System.monotonic_time(:millisecond)` value this render must
    finish by; the render gets whichever is smaller, it or the per-page timeout
  """
  # output_dir is the generated document UUID/pages directory; output names use a fixed page prefix.
  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def extract_page(pdf_path, output_dir, page_number, opts \\ []) do
    with {:ok, timeout} <- budget(opts, PdfExtraction.timeout()) do
      File.mkdir_p!(output_dir)

      page = to_string(page_number)
      args = ["-f", page, "-l", page] ++ render_args(pdf_path, output_dir, opts)

      with {:ok, _output} <- render(args, timeout),
           {:ok, path} <- locate_page_image(output_dir, page_number),
           :ok <- check_image_size(path, page_number) do
        {:ok, path}
      end
    end
  end

  @doc """
  Gets the number of pages in a PDF without extracting.

  Documents above the configured `:max_pages`, and documents whose pages would
  rasterize above `:max_page_pixels`, are rejected here — before any page is
  rendered. This is the one call that decides how much extraction work follows.
  """
  @impl true
  def get_page_count(pdf_path) do
    with {:ok, executable} <- resolve(:pdfinfo_path, "pdfinfo"),
         {:ok, output} <-
           run(executable, [pdf_path], PdfExtraction.info_timeout(),
             failure_tag: :pdfinfo_failed,
             timeout_tag: :pdfinfo_timeout
           ),
         {:ok, count} <- parse_page_count(output),
         :ok <- check_page_geometry(output) do
      check_page_count(count)
    end
  end

  @doc """
  Returns the path to a specific page image.

  Page numbers are 1-indexed.
  """
  @impl true
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
  @impl true
  def list_page_images(output_dir) do
    pattern = Path.join(output_dir, "page-*.png")

    pattern
    |> Path.wildcard()
    |> Enum.sort_by(&extract_page_number/1)
  end

  @doc """
  Checks if the poppler commands extraction needs are available.

  Both are required: every extraction calls `pdfinfo` before it renders anything.
  """
  @impl true
  def available? do
    match?({:ok, _path}, resolve(:pdftoppm_path, "pdftoppm")) and
      match?({:ok, _path}, resolve(:pdfinfo_path, "pdfinfo"))
  end

  # Private functions

  defp render_args(pdf_path, output_dir, opts) do
    ["-png", "-r", to_string(dpi(opts)), pdf_path, Path.join(output_dir, "page")]
  end

  defp dpi(opts), do: Keyword.get(opts, :dpi, PdfExtraction.dpi())

  # A whole-document render may take the per-page budget for each of its pages,
  # but never longer than the job containing it would wait: multiplying the
  # per-page ceiling by the page limit alone would rebuild the unbounded wait
  # this module exists to prevent.
  defp document_ceiling(page_count) do
    # A malformed `Pages: 0` must not turn into a zero-millisecond deadline.
    min(max(page_count, 1) * PdfExtraction.timeout(), PdfExtraction.job_timeout())
  end

  # Clamps a command's timeout to the caller's remaining document budget, so
  # per-page deadlines cannot add up past the job that contains them.
  defp budget(opts, ceiling) do
    case Keyword.get(opts, :deadline) do
      nil ->
        {:ok, ceiling}

      deadline ->
        case deadline - System.monotonic_time(:millisecond) do
          remaining when remaining > 0 -> {:ok, min(ceiling, remaining)}
          _expired -> {:error, :pdf_extraction_deadline_exceeded}
        end
    end
  end

  defp render(args, timeout) do
    with {:ok, executable} <- resolve(:pdftoppm_path, "pdftoppm") do
      run(executable, args, timeout,
        failure_tag: :pdf_command_failed,
        timeout_tag: :pdf_command_timeout
      )
    end
  end

  # Runs one poppler command under a deadline. `:failure_tag` names a non-zero
  # exit and `:timeout_tag` a deadline for the caller, so a hung `pdfinfo` is not
  # reported as a rendering problem; everything else is a failure of the command
  # itself, with the output the subprocess kept.
  defp run(executable, args, timeout, tags) do
    fn -> Subprocess.run(executable, args, timeout: timeout) end
    |> Subprocess.supervised()
    |> classify(executable, timeout, tags)
  end

  defp classify({:ok, {output, 0}}, _executable, _timeout, _tags), do: {:ok, output}

  defp classify({:ok, {output, exit_code}}, executable, _timeout, tags) do
    diagnostic = Subprocess.diagnostic(output)

    Logger.error(
      "#{executable} failed with exit code #{exit_code}: " <> String.slice(diagnostic, 0, 500)
    )

    {:error, {Keyword.fetch!(tags, :failure_tag), [error: diagnostic]}}
  end

  defp classify({:timeout, output}, executable, timeout, tags) do
    diagnostic = Subprocess.diagnostic(output)

    Logger.error(
      "#{executable} timed out after #{timeout}ms: " <> String.slice(diagnostic, 0, 500)
    )

    {:error, Keyword.fetch!(tags, :timeout_tag)}
  end

  defp classify({:start_error, message}, _executable, _timeout, _tags),
    do: {:error, {:pdf_command_failed, [error: Subprocess.diagnostic(message)]}}

  defp classify({:error, reason}, _executable, _timeout, _tags),
    do: {:error, {:pdf_command_failed, [error: inspect(reason)]}}

  defp classify({:subprocess_owner_down, reason}, _executable, _timeout, _tags),
    do: {:error, {:pdf_command_failed, [error: inspect(reason)]}}

  defp parse_page_count(output) do
    case Regex.run(~r/Pages:\s*(\d+)/, output) do
      [_, count] -> {:ok, String.to_integer(count)}
      _no_match -> {:error, :invalid_page_count}
    end
  end

  defp check_page_count(count) do
    limit = PdfExtraction.max_pages()

    if count > limit do
      {:error, {:pdf_too_many_pages, [pages: count, limit: limit]}}
    else
      {:ok, count}
    end
  end

  # Rejects geometry that would rasterize past the pixel limit. `pdfinfo` reports
  # the first page's media box; a document whose pages differ can still slip a
  # later page through, which is what the post-render byte check is for.
  defp check_page_geometry(output) do
    case parse_page_size(output) do
      {:ok, {width_pts, height_pts}} -> check_page_pixels(width_pts, height_pts)
      # Nothing to check against: some builds omit the line entirely.
      :error -> :ok
    end
  end

  defp check_page_pixels(width_pts, height_pts) do
    dpi = PdfExtraction.dpi()
    limit = PdfExtraction.max_page_pixels()
    width = round(width_pts / @points_per_inch * dpi)
    height = round(height_pts / @points_per_inch * dpi)
    pixels = width * height

    if pixels > limit do
      {:error,
       {:pdf_page_too_large,
        [width: width, height: height, pixels: pixels, limit: limit, dpi: dpi]}}
    else
      :ok
    end
  end

  defp parse_page_size(output) do
    case Regex.run(~r/Page size:\s*([\d.]+)\s*x\s*([\d.]+)\s*pts/, output) do
      [_, width, height] -> {:ok, {parse_float(width), parse_float(height)}}
      _no_match -> :error
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp locate_page_image(output_dir, page_number) do
    case page_image_path(output_dir, page_number) do
      nil -> {:error, :page_image_not_found}
      path -> {:ok, path}
    end
  end

  # Every oversized render is deleted, not just the first: a leftover image is
  # what a retry treats as "this page is already extracted", so stopping at the
  # first offender would leave the later ones to be picked up as finished pages.
  defp check_image_sizes(output_dir) do
    output_dir
    |> list_page_images()
    |> Enum.map(&check_image_size(&1, extract_page_number(&1)))
    |> Enum.find(:ok, &match?({:error, _reason}, &1))
  end

  # An oversized render is removed rather than left behind: the stored image is
  # what a retry treats as "this page is already extracted", so keeping it would
  # make a lower `:dpi` setting take no effect until the file is deleted by hand.
  # The path comes from the extractor's own wildcard over the pages directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp check_image_size(path, page_number) do
    limit = PdfExtraction.max_image_bytes()

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > limit ->
        _ = File.rm(path)
        {:error, {:page_image_too_large, [page_number: page_number, size: size, limit: limit]}}

      _other ->
        :ok
    end
  end

  # Resolves a poppler executable the same way `soffice` resolves: an explicit
  # configured path, then `PATH`, then the known install locations.
  defp resolve(config_key, name) do
    candidates = Enum.map(PdfExtraction.search_dirs(), &Path.join(&1, name))

    case Executable.resolve(name,
           configured: PdfExtraction.executable_path(config_key),
           candidates: candidates
         ) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, {:poppler_not_found, [command: name]}}
    end
  end

  defp extract_page_number(file_path) do
    file_path
    |> Path.basename(".png")
    |> String.replace(~r/^page-0*/, "")
    |> String.to_integer()
  end
end
