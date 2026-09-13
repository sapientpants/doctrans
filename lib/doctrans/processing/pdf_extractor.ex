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

  Two limits bound the work a single document can ask for, both configurable under
  `:pdf_extraction`: `:max_pages` rejects a document before any page is rendered,
  and `:max_image_bytes` rejects a page whose rendered image is too large to be
  worth sending to a model. Both report the value and the limit, so the answer is
  either a smaller document or a lower `:dpi`.
  """

  @behaviour Doctrans.Processing.PdfExtractorBehaviour

  require Logger

  alias Doctrans.Processing.Subprocess

  @default_dpi 200
  @default_timeout 120_000
  @default_info_timeout 15_000
  @default_max_pages 1_000
  @default_max_image_bytes 20_000_000

  @doc """
  Extracts all pages from a PDF file as PNG images.

  Returns `{:ok, page_count}` on success or `{:error, reason}` on failure.

  The deadline covers the whole document: `get_page_count/1` establishes how many
  pages there are (and rejects a document over `:max_pages`), and the renderer gets
  the per-page timeout for each of them.

  ## Options

  - `:dpi` - Resolution in DPI (default: from config, fallback 200)
  """
  # output_dir is the generated document UUID/pages directory supplied by PdfProcessor.
  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def extract_pages(pdf_path, output_dir, opts \\ []) do
    with {:ok, page_count} <- get_page_count(pdf_path) do
      File.mkdir_p!(output_dir)

      args = render_args(pdf_path, output_dir, opts)

      Logger.info("Extracting pages from #{pdf_path} to #{output_dir}")

      # A malformed `Pages: 0` must not turn into a zero-millisecond deadline.
      with {:ok, _output} <- render(args, max(page_count, 1) * timeout()),
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

  - `:dpi` - Resolution in DPI (default: from config, fallback 200)
  """
  # output_dir is the generated document UUID/pages directory; output names use a fixed page prefix.
  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def extract_page(pdf_path, output_dir, page_number, opts \\ []) do
    File.mkdir_p!(output_dir)

    page = to_string(page_number)
    args = ["-f", page, "-l", page] ++ render_args(pdf_path, output_dir, opts)

    with {:ok, _output} <- render(args, timeout()),
         {:ok, path} <- locate_page_image(output_dir, page_number),
         :ok <- check_image_size(path, page_number) do
      {:ok, path}
    end
  end

  @doc """
  Gets the number of pages in a PDF without extracting.

  Documents above the configured `:max_pages` are rejected here, before any page
  is rendered: this is the one call that decides how much extraction work follows.
  """
  @impl true
  def get_page_count(pdf_path) do
    with {:ok, executable} <- resolve(:pdfinfo_path, "pdfinfo"),
         {:ok, output} <-
           run(executable, [pdf_path], info_timeout(), :pdfinfo_failed),
         {:ok, count} <- parse_page_count(output) do
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
  Checks if pdftoppm is available on the system.
  """
  @impl true
  def available? do
    match?({:ok, _path}, resolve(:pdftoppm_path, "pdftoppm"))
  end

  # Private functions

  defp render_args(pdf_path, output_dir, opts) do
    dpi = Keyword.get(opts, :dpi, setting(:dpi, @default_dpi))

    ["-png", "-r", to_string(dpi), pdf_path, Path.join(output_dir, "page")]
  end

  defp render(args, timeout) do
    with {:ok, executable} <- resolve(:pdftoppm_path, "pdftoppm") do
      run(executable, args, timeout, :pdf_command_failed)
    end
  end

  # Runs one poppler command under a deadline. `failure_tag` names the non-zero
  # exit for the caller; everything else is a failure of the command itself and
  # reports as one, with the output the subprocess kept.
  defp run(executable, args, timeout, failure_tag) do
    fn -> Subprocess.run(executable, args, timeout: timeout) end
    |> Subprocess.supervised()
    |> classify(executable, timeout, failure_tag)
  end

  defp classify({:ok, {output, 0}}, _executable, _timeout, _failure_tag), do: {:ok, output}

  defp classify({:ok, {output, exit_code}}, executable, _timeout, failure_tag) do
    Logger.error(
      "#{executable} failed with exit code #{exit_code}: " <> String.slice(output, 0, 500)
    )

    {:error, {failure_tag, [error: String.trim(output)]}}
  end

  defp classify({:timeout, output}, executable, timeout, _failure_tag) do
    Logger.error("#{executable} timed out after #{timeout}ms: #{String.slice(output, 0, 500)}")

    {:error, :pdf_command_timeout}
  end

  defp classify({:start_error, message}, _executable, _timeout, _failure_tag),
    do: {:error, {:pdf_command_failed, [error: String.trim(message)]}}

  defp classify({:error, reason}, _executable, _timeout, _failure_tag),
    do: {:error, {:pdf_command_failed, [error: inspect(reason)]}}

  defp classify({:subprocess_owner_down, reason}, _executable, _timeout, _failure_tag),
    do: {:error, {:pdf_command_failed, [error: inspect(reason)]}}

  defp parse_page_count(output) do
    case Regex.run(~r/Pages:\s*(\d+)/, output) do
      [_, count] -> {:ok, String.to_integer(count)}
      _no_match -> {:error, :invalid_page_count}
    end
  end

  defp check_page_count(count) do
    limit = setting(:max_pages, @default_max_pages)

    if count > limit do
      {:error, {:pdf_too_many_pages, [pages: count, limit: limit]}}
    else
      {:ok, count}
    end
  end

  defp locate_page_image(output_dir, page_number) do
    case page_image_path(output_dir, page_number) do
      nil -> {:error, :page_image_not_found}
      path -> {:ok, path}
    end
  end

  defp check_image_sizes(output_dir) do
    output_dir
    |> list_page_images()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case check_image_size(path, extract_page_number(path)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # An oversized render is removed rather than left behind: the stored image is
  # what a retry treats as "this page is already extracted", so keeping it would
  # make a lower `:dpi` setting take no effect until the file is deleted by hand.
  # The path comes from the extractor's own wildcard over the pages directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp check_image_size(path, page_number) do
    limit = setting(:max_image_bytes, @default_max_image_bytes)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > limit ->
        _ = File.rm(path)
        {:error, {:page_image_too_large, [page_number: page_number, size: size, limit: limit]}}

      _other ->
        :ok
    end
  end

  # Resolves a poppler executable: an explicit configured path when it is
  # executable, otherwise the first match on `PATH`.
  defp resolve(config_key, name) do
    configured = setting(config_key, nil)

    case (executable_file?(configured) && configured) || System.find_executable(name) do
      nil -> {:error, {:poppler_not_found, [command: name]}}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp executable_file?(path) do
    case is_binary(path) && File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> :erlang.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp extract_page_number(file_path) do
    file_path
    |> Path.basename(".png")
    |> String.replace(~r/^page-0*/, "")
    |> String.to_integer()
  end

  defp timeout, do: setting(:timeout, @default_timeout)
  defp info_timeout, do: setting(:info_timeout, @default_info_timeout)

  defp setting(key, default) do
    :doctrans
    |> Application.get_env(:pdf_extraction, [])
    |> Keyword.get(key, default)
  end
end
