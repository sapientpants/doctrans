defmodule Doctrans.Processing.ResumablePdfExtractorStub do
  @moduledoc false

  alias Doctrans.Processing.PdfExtractorStub

  defdelegate get_page_count(path), to: PdfExtractorStub

  def extract_page(path, directory, page_number, opts) do
    send(self(), {:extracted_pdf_page, page_number})

    if Process.get(:fail_pdf_page) == page_number do
      {:error, :invalid_pdf}
    else
      PdfExtractorStub.extract_page(path, directory, page_number, opts)
    end
  end
end
