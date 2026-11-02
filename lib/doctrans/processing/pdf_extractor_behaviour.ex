defmodule Doctrans.Processing.PdfExtractorBehaviour do
  @moduledoc """
  Behaviour for PDF extraction.

  This allows mocking the PDF extraction in tests. The pipeline dispatches
  `get_page_count/1` once per document and `extract_page/4` once per page;
  `available?/0` is for readiness reporting.
  """

  @callback extract_page(
              pdf_path :: String.t(),
              output_dir :: String.t(),
              page_number :: integer(),
              opts :: keyword()
            ) ::
              {:ok, String.t()} | {:error, Doctrans.Errors.reason()}

  @callback get_page_count(pdf_path :: String.t()) ::
              {:ok, integer()} | {:error, Doctrans.Errors.reason()}

  @callback available?() :: boolean()
end
