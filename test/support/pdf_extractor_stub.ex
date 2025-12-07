defmodule Doctrans.Processing.PdfExtractorStub do
  @moduledoc """
  Stub implementation of PdfExtractorBehaviour for tests.

  Creates fake page images that can be used in tests without
  requiring the actual pdftoppm utility.
  """

  @behaviour Doctrans.Processing.PdfExtractorBehaviour

  @impl true
  def extract_pages(pdf_path, output_dir, opts \\ [])

  def extract_pages(_pdf_path, output_dir, opts) do
    page_count = Keyword.get(opts, :page_count, 3)

    # Create fake page images
    File.mkdir_p!(output_dir)

    for page_num <- 1..page_count do
      padded = String.pad_leading(to_string(page_num), 2, "0")
      file_path = Path.join(output_dir, "page-#{padded}.png")
      # Create a minimal PNG file (1x1 pixel transparent PNG)
      File.write!(file_path, minimal_png())
    end

    {:ok, page_count}
  end

  @impl true
  def extract_page(_pdf_path, output_dir, page_number, _opts \\ []) do
    File.mkdir_p!(output_dir)

    padded = String.pad_leading(to_string(page_number), 2, "0")
    file_path = Path.join(output_dir, "page-#{padded}.png")
    # Create a minimal PNG file (1x1 pixel transparent PNG)
    File.write!(file_path, minimal_png())

    {:ok, file_path}
  end

  @impl true
  def get_page_count(_pdf_path) do
    {:ok, 3}
  end

  @impl true
  def page_image_path(output_dir, page_number) do
    padded = String.pad_leading(to_string(page_number), 2, "0")
    path = Path.join(output_dir, "page-#{padded}.png")

    if File.exists?(path) do
      path
    else
      nil
    end
  end

  @impl true
  def list_page_images(output_dir) do
    pattern = Path.join(output_dir, "page-*.png")

    pattern
    |> Path.wildcard()
    |> Enum.sort()
  end

  @impl true
  def available? do
    true
  end

  # Minimal valid PNG (1x1 transparent pixel)
  defp minimal_png do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1,
      13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
