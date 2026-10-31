defmodule Doctrans.Deps do
  @moduledoc """
  The external collaborators tests replace with Mox mocks.

  Each lookup reads the application environment key `config/test.exs` points at
  a `*Mock` module (`Doctrans.Mocks` installs the default stubs), and falls back
  to the real implementation everywhere else. Callers go through these functions
  rather than naming the module, so the seam is one line per collaborator
  instead of a private lookup repeated in every module that talks to it.
  """

  @doc "The chat and vision client, `Doctrans.Processing.OpenAI` unless configured."
  @spec openai() :: module()
  def openai, do: Application.get_env(:doctrans, :openai_module, Doctrans.Processing.OpenAI)

  @doc "The embedding client, `Doctrans.Search.Embedding` unless configured."
  @spec embedding() :: module()
  def embedding, do: Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)

  @doc "The poppler wrapper, `Doctrans.Processing.PdfExtractor` unless configured."
  @spec pdf_extractor() :: module()
  def pdf_extractor,
    do: Application.get_env(:doctrans, :pdf_extractor_module, Doctrans.Processing.PdfExtractor)

  @doc "The LibreOffice wrapper, `Doctrans.Processing.DocumentConverter` unless configured."
  @spec document_converter() :: module()
  def document_converter,
    do:
      Application.get_env(
        :doctrans,
        :document_converter_module,
        Doctrans.Processing.DocumentConverter
      )
end
