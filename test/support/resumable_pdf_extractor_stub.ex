defmodule Doctrans.Processing.ResumablePdfExtractorStub do
  @moduledoc """
  A page extractor the calling process can pause or fail on a chosen page.

  `install/0` stubs `extract_page/4` on `Doctrans.Processing.PdfExtractorMock`
  for the running test; the other callbacks keep the default stub. Each
  extracted page is reported to the extracting process as
  `{:extracted_pdf_page, page_number}`. With `:pause_pdf_page` set to
  `{page_number, owner}` in that process's dictionary, the stub tells `owner`
  `{:pdf_page_paused, page_number}` and waits for `:resume_pdf`; with
  `:fail_pdf_page` set to a page number, that page fails with `:invalid_pdf`.
  """

  import Mox

  alias Doctrans.Processing.{PdfExtractorMock, PdfExtractorStub}

  @doc "Routes `extract_page/4` through this stub for the running test."
  def install do
    stub(PdfExtractorMock, :extract_page, &extract_page/4)
    :ok
  end

  def extract_page(path, directory, page_number, opts) do
    send(self(), {:extracted_pdf_page, page_number})

    case Process.get(:pause_pdf_page) do
      {^page_number, owner} ->
        send(owner, {:pdf_page_paused, page_number})

        receive do
          :resume_pdf -> :ok
        after
          5_000 -> raise "Timed out waiting to resume PDF extraction"
        end

      _ ->
        :ok
    end

    if Process.get(:fail_pdf_page) == page_number do
      {:error, :invalid_pdf}
    else
      PdfExtractorStub.extract_page(path, directory, page_number, opts)
    end
  end
end
