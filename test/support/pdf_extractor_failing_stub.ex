defmodule Doctrans.Processing.PdfExtractorFailingStub do
  @moduledoc """
  A `PdfExtractorBehaviour` that fails `get_page_count/1` with a configured reason.

  Mox runs in global mode in this suite, so a single test cannot install its own
  stub. Tests that need extraction to fail a particular way point
  `:pdf_extractor_module` at this module and set `:test_extraction_failure`.
  """

  @behaviour Doctrans.Processing.PdfExtractorBehaviour

  @impl true
  defdelegate extract_pages(pdf_path, output_dir, opts \\ []),
    to: Doctrans.Processing.PdfExtractorStub

  @impl true
  defdelegate extract_page(pdf_path, output_dir, page_number, opts \\ []),
    to: Doctrans.Processing.PdfExtractorStub

  @impl true
  defdelegate page_image_path(output_dir, page_number), to: Doctrans.Processing.PdfExtractorStub

  @impl true
  defdelegate list_page_images(output_dir), to: Doctrans.Processing.PdfExtractorStub

  @impl true
  def available?, do: true

  @impl true
  def get_page_count(_pdf_path) do
    {:error, Application.get_env(:doctrans, :test_extraction_failure, :unknown)}
  end
end
