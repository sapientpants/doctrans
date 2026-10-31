defmodule Doctrans.Documents.FormatsTest do
  use ExUnit.Case, async: true

  alias Doctrans.Documents.Formats

  describe "supported_extensions/0" do
    test "lists PDF and every convertible format, lowercase and dotted" do
      extensions = Formats.supported_extensions()

      assert ".pdf" in extensions
      assert Enum.sort(extensions) == Enum.sort([".pdf" | Formats.convertible_extensions()])
      assert Enum.all?(extensions, &(String.starts_with?(&1, ".") and &1 == String.downcase(&1)))
    end

    test "convertible formats are the ones that go through LibreOffice" do
      assert Enum.sort(Formats.convertible_extensions()) == ~w(.doc .docx .odt .rtf)
      refute ".pdf" in Formats.convertible_extensions()
    end
  end

  describe "supported?/1" do
    test "accepts each supported extension and nothing else" do
      for extension <- Formats.supported_extensions(), do: assert(Formats.supported?(extension))

      refute Formats.supported?(".txt")
      refute Formats.supported?(".xlsx")
      refute Formats.supported?(".pptx")
      refute Formats.supported?(".png")
      refute Formats.supported?(nil)
    end

    test "expects the lowercase, dotted shape extension/1 produces" do
      refute Formats.supported?(".PDF")
      refute Formats.supported?("pdf")
      assert Formats.supported?(Formats.extension("DOCUMENT.PDF"))
    end
  end

  describe "extension/1" do
    test "returns the downcased extension with its dot" do
      assert Formats.extension("report.DocX") == ".docx"
      assert Formats.extension("/tmp/uploads/original.pdf") == ".pdf"
    end

    test "is empty for a path with no extension" do
      assert Formats.extension("README") == ""
      refute Formats.supported?(Formats.extension("README"))
    end
  end
end
