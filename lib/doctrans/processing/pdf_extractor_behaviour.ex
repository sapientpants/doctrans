defmodule Doctrans.Processing.PdfExtractorBehaviour do
  @moduledoc """
  Behaviour for PDF extraction.

  This allows mocking the PDF extraction in tests.
  """

  @callback extract_pages(pdf_path :: String.t(), output_dir :: String.t(), opts :: keyword()) ::
              {:ok, integer()} | {:error, Doctrans.Errors.reason()}

  @callback extract_page(
              pdf_path :: String.t(),
              output_dir :: String.t(),
              page_number :: integer(),
              opts :: keyword()
            ) ::
              {:ok, String.t()} | {:error, Doctrans.Errors.reason()}

  @callback get_page_count(pdf_path :: String.t()) ::
              {:ok, integer()} | {:error, Doctrans.Errors.reason()}

  @callback page_image_path(output_dir :: String.t(), page_number :: integer()) ::
              String.t() | nil

  @callback list_page_images(output_dir :: String.t()) :: [String.t()]

  @callback available?() :: boolean()
end
