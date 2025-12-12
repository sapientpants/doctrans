defmodule Doctrans.Processing.DocumentProcessorTest do
  use ExUnit.Case, async: true

  alias Doctrans.Processing.DocumentProcessor

  describe "supported_format?/1" do
    test "returns true for PDF files" do
      assert DocumentProcessor.supported_format?("document.pdf")
      assert DocumentProcessor.supported_format?("DOCUMENT.PDF")
    end

    test "returns true for Word files" do
      assert DocumentProcessor.supported_format?("document.docx")
      assert DocumentProcessor.supported_format?("document.doc")
      assert DocumentProcessor.supported_format?("DOCUMENT.DOCX")
    end

    test "returns true for OpenDocument files" do
      assert DocumentProcessor.supported_format?("document.odt")
    end

    test "returns true for RTF files" do
      assert DocumentProcessor.supported_format?("document.rtf")
    end

    test "returns false for unsupported formats" do
      refute DocumentProcessor.supported_format?("document.txt")
      refute DocumentProcessor.supported_format?("document.xlsx")
      refute DocumentProcessor.supported_format?("document.pptx")
      refute DocumentProcessor.supported_format?("image.png")
    end
  end

  describe "supported_extensions/0" do
    test "returns list of supported extensions" do
      extensions = DocumentProcessor.supported_extensions()

      assert is_list(extensions)
      assert ".pdf" in extensions
      assert ".docx" in extensions
      assert ".doc" in extensions
      assert ".odt" in extensions
      assert ".rtf" in extensions
    end
  end
end
