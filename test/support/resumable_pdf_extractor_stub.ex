defmodule Doctrans.Processing.ResumablePdfExtractorStub do
  @moduledoc false

  alias Doctrans.Processing.PdfExtractorStub

  defdelegate get_page_count(path), to: PdfExtractorStub

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
