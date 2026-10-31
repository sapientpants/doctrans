defmodule Doctrans.DepsTest do
  # Reads the application environment the test config sets, which is global.
  use ExUnit.Case, async: false

  alias Doctrans.Deps

  test "each lookup resolves to the mock config/test.exs installs" do
    assert Deps.openai() == Doctrans.Processing.OpenAIMock
    assert Deps.embedding() == Doctrans.Search.EmbeddingMock
    assert Deps.pdf_extractor() == Doctrans.Processing.PdfExtractorMock
    assert Deps.document_converter() == Doctrans.Processing.DocumentConverterMock
  end
end
