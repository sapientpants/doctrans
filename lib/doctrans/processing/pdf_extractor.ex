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
    `pdfinfo` is asked for every page's geometry, not just the first page's, and
    a document any of whose pages it does not report a size for is rejected
    rather than rendered on trust. The bound is then held a second time at the
    render: each page is measured again just before `pdftoppm` runs, and the
    render is pinned to the measured pixel dimensions, so a page cannot
    rasterize to more than what was checked.
  - `:max_image_bytes` rejects a rendered page too large to be worth sending to a
    model, and deletes it
  - `:timeout` bounds one render, and a `:deadline` passed by the caller bounds
    the document as a whole, so per-page bounds cannot add up past the job that
    contains them

  Each reports the value and the limit, so the answer is either a smaller
  document or a lower `:dpi`.
  """

  @behaviour Doctrans.Processing.PdfExtractorBehaviour

  alias Doctrans.Config.PdfExtraction
  alias Doctrans.Processing.Executable
  alias Doctrans.Processing.Subprocess

  # PDF user-space units are 1/72 inch.
  @points_per_inch 72

  # One `Page N size:` line per page when a range was given, or a single
  # `Page size:` line from a build that ignores the range; either way the line
  # starts the line, so metadata that merely contains those words is not read as
  # geometry. The dimensions are taken as whatever stands between `size:` and
  # `pts` and parsed afterwards: pdfinfo prints them with `%g`, so a page a
  # million points wide prints as `1e+06`, and a pattern that only admitted
  # digits would skip exactly the page this bound exists for.
  @size_line ~r/^Page(?:\s+(\d+))? size:\s+(\S+)\s*x\s*(\S+)\s*pts/m

  @doc """
  Extracts a single page from a PDF file as a PNG image.

  Returns `{:ok, image_path}` on success or `{:error, reason}` on failure.

  ## Options

  - `:deadline` - a `System.monotonic_time(:millisecond)` value this render must
    finish by; the render gets whichever is smaller, it or the per-page timeout

  The page is measured with `pdfinfo` first and checked against
  `:max_page_pixels` at the configured `:dpi`, as `get_page_count/1` already
  did for the whole document, and the render is then pinned to those pixel
  dimensions rather than left to `pdftoppm`'s own reading of the page.
  """
  # output_dir is the generated document UUID/pages directory; output names use a fixed page prefix.
  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def extract_page(pdf_path, output_dir, page_number, opts \\ []) do
    with {:ok, renderer} <- resolve(:pdftoppm_path, "pdftoppm"),
         {:ok, {width, height}} <- measure_page(pdf_path, page_number, opts),
         {:ok, timeout} <- budget(opts, PdfExtraction.timeout()) do
      File.mkdir_p!(output_dir)
      args = render_args(pdf_path, output_dir, page_number, width, height)

      with {:ok, _output} <-
             run(renderer, args, timeout,
               failure_tag: :pdf_command_failed,
               timeout_tag: :pdf_command_timeout
             ),
           {:ok, path} <- locate_page_image(output_dir, page_number),
           :ok <- check_image_size(path, page_number) do
        {:ok, path}
      end
    end
  end

  @doc """
  Gets the number of pages in a PDF without extracting.

  Documents above the configured `:max_pages`, and documents any of whose pages
  would rasterize above `:max_page_pixels`, are rejected here — before any page
  is rendered. This is the one call that decides how much extraction work
  follows, so it is the one call a document could lie to: `pdfinfo` is asked for
  the geometry of every page up to `:max_pages`, only lines it prints for a page
  count toward the answer, never a look-alike inside the document's own
  metadata, and a page it prints no size for fails the document.
  """
  @impl true
  def get_page_count(pdf_path) do
    with {:ok, output} <-
           info(pdf_path, 1, PdfExtraction.max_pages(), PdfExtraction.info_timeout()),
         {:ok, count} <- parse_page_count(output),
         {:ok, count} <- check_page_count(count),
         {:ok, sizes} <- parse_page_sizes(output, Range.new(1, count, 1)),
         :ok <- check_page_geometry(sizes) do
      {:ok, count}
    end
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

  # The render is pinned to the pixel dimensions the page was measured at, not
  # left to a resolution: `-scale-to-x`/`-scale-to-y` make pdftoppm rasterize to
  # exactly this many pixels whatever the page's geometry turns out to be, so a
  # page that reads one way to pdfinfo and another to pdftoppm still cannot
  # allocate more than what passed the bound. For an honest page the result is
  # the one `-r` would have produced, since the dimensions are the ones pdftoppm
  # itself derives from the configured `:dpi`.
  defp render_args(pdf_path, output_dir, page_number, width, height) do
    page = to_string(page_number)

    [
      "-f",
      page,
      "-l",
      page,
      "-png",
      "-scale-to-x",
      to_string(width),
      "-scale-to-y",
      to_string(height),
      pdf_path,
      Path.join(output_dir, "page")
    ]
  end

  # Without a page range `pdfinfo` reports the size of the first page only, and
  # a small first page says nothing about the ones behind it. With one it prints
  # a `Page N size:` line for every page in the range; asking for up to
  # `:max_pages` covers every page an accepted document can have, and a document
  # with more is rejected by its count before its geometry matters.
  defp info(pdf_path, first, last, timeout) do
    with {:ok, executable} <- resolve(:pdfinfo_path, "pdfinfo") do
      run(executable, ["-f", to_string(first), "-l", to_string(last), pdf_path], timeout,
        failure_tag: :pdfinfo_failed,
        timeout_tag: :pdfinfo_timeout
      )
    end
  end

  # Measures the one page about to be rendered and returns its pixel dimensions
  # at the configured `:dpi`, or the same `:pdf_page_too_large` error the
  # document-wide check would have given. Measuring again here, rather than
  # trusting the earlier `get_page_count/1`, keeps the render self-contained:
  # whatever reached it, nothing is rasterized at a size this call did not see.
  defp measure_page(pdf_path, page_number, opts) do
    with {:ok, timeout} <- budget(opts, PdfExtraction.info_timeout()),
         {:ok, output} <- info(pdf_path, page_number, page_number, timeout),
         {:ok, [size]} <- parse_page_sizes(output, page_number..page_number//1) do
      page_dimensions(size)
    end
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

  # Runs one poppler command under a deadline. `:failure_tag` names a non-zero
  # exit and `:timeout_tag` a deadline for the caller, so a hung `pdfinfo` is not
  # reported as a rendering problem. A command that never ran to an exit is a
  # failure of that same command, so it shares the `:failure_tag`: the user-facing
  # copy names the tool, and a `pdfinfo` that failed to start must not be
  # reported as `pdftoppm`.
  defp run(executable, args, timeout, tags) do
    failure_tag = Keyword.fetch!(tags, :failure_tag)

    fn -> Subprocess.run(executable, args, timeout: timeout) end
    |> Subprocess.supervised()
    |> Subprocess.classify(
      name: executable,
      timeout: timeout,
      failure_tag: failure_tag,
      start_tag: failure_tag,
      timeout_tag: Keyword.fetch!(tags, :timeout_tag)
    )
  end

  # Anchored to the start of a line. `pdfinfo` prints the document's Info
  # dictionary (`Title:`, `Subject:`, `Keywords:`) before `Pages:`, and prints
  # the metadata's own newlines as `?`, so a title that reads "Pages: 1" sits
  # mid-line where this cannot match it.
  defp parse_page_count(output) do
    case Regex.run(~r/^Pages:\s+(\d+)\s*$/m, output) do
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

  # The sizes of exactly the pages asked for, in order, or `:invalid_page_size`.
  # Every page in the range must have a line and every line must parse: this is
  # the one bound that must hold before the render, so a page with no size, or
  # a size that reads as nothing, cannot mean "go ahead". A page the line does
  # not number is taken in order of appearance from the first page asked for.
  defp parse_page_sizes(output, pages) do
    sizes =
      @size_line
      |> Regex.scan(output)
      |> Enum.with_index(pages.first)
      |> Enum.map(&parse_size_line/1)

    if Enum.all?(sizes, &is_tuple/1) and Enum.map(sizes, &elem(&1, 0)) == Enum.to_list(pages) do
      {:ok, sizes}
    else
      {:error, :invalid_page_size}
    end
  end

  # One matched size line as `{page_number, width_pts, height_pts}`, or
  # `:error` when either dimension does not read as a number.
  defp parse_size_line({[_line, number, width, height], position}) do
    with {:ok, width} <- parse_points(width),
         {:ok, height} <- parse_points(height) do
      {page_number(number, position), width, height}
    end
  end

  defp page_number("", position), do: position
  defp page_number(number, _position), do: String.to_integer(number)

  # A dimension is a positive number and nothing else; `Float.parse/1` rejects
  # what does not fit a float, including magnitudes past its range.
  defp parse_points(value) do
    case Float.parse(value) do
      {points, ""} when points > 0 -> {:ok, points}
      _other -> :error
    end
  end

  # Rejects any page whose geometry would rasterize past the pixel limit. Every
  # page is checked, in order, and the first one over the limit names itself in
  # the error.
  defp check_page_geometry(sizes) do
    Enum.reduce_while(sizes, :ok, fn size, :ok ->
      case page_dimensions(size) do
        {:ok, _dimensions} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The pixel dimensions a page renders to at the configured `:dpi`, or the
  # `:pdf_page_too_large` error when they multiply out past the limit.
  defp page_dimensions({page_number, width_pts, height_pts}) do
    dpi = PdfExtraction.dpi()
    limit = PdfExtraction.max_page_pixels()
    width = pixels(width_pts, dpi)
    height = pixels(height_pts, dpi)
    pixel_count = width * height

    if pixel_count > limit do
      {:error,
       {:pdf_page_too_large,
        [
          page_number: page_number,
          width: width,
          height: height,
          pixels: pixel_count,
          limit: limit,
          dpi: dpi
        ]}}
    else
      {:ok, {width, height}}
    end
  end

  # Rounded up, as pdftoppm rounds a page's pixel dimensions, so the dimensions
  # the render is pinned to are the ones it would have chosen itself.
  defp pixels(points, dpi) do
    (points * dpi / @points_per_inch) |> Float.ceil() |> trunc()
  end

  # pdftoppm names its output page-01.png, page-02.png and so on, with as many
  # digits as the page count needs, so the file is found by its number rather
  # than by a name this module would have to agree with poppler on.
  defp locate_page_image(output_dir, page_number) do
    output_dir
    |> Path.join("page-*.png")
    |> Path.wildcard()
    |> Enum.find(&(extract_page_number(&1) == page_number))
    |> case do
      nil -> {:error, :page_image_not_found}
      path -> {:ok, path}
    end
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
