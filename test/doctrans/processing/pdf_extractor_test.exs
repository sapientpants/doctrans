defmodule Doctrans.Processing.PdfExtractorTest do
  use ExUnit.Case, async: true

  alias Doctrans.Processing.PdfExtractor

  describe "available?/0" do
    test "returns boolean" do
      result = PdfExtractor.available?()
      assert is_boolean(result)
    end
  end

  describe "list_page_images/1" do
    test "returns empty list for non-existent directory" do
      result = PdfExtractor.list_page_images("/nonexistent/directory")
      assert result == []
    end

    test "returns sorted list of page images" do
      dir = Path.join(System.tmp_dir!(), "pdf_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)

      # Create test files out of order
      File.write!(Path.join(dir, "page-03.png"), "")
      File.write!(Path.join(dir, "page-01.png"), "")
      File.write!(Path.join(dir, "page-02.png"), "")

      result = PdfExtractor.list_page_images(dir)

      assert length(result) == 3
      assert Enum.at(result, 0) =~ "page-01.png"
      assert Enum.at(result, 1) =~ "page-02.png"
      assert Enum.at(result, 2) =~ "page-03.png"

      # Cleanup
      File.rm_rf!(dir)
    end
  end

  describe "page_image_path/2" do
    test "returns nil for non-existent page" do
      dir = Path.join(System.tmp_dir!(), "pdf_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)

      result = PdfExtractor.page_image_path(dir, 1)
      assert result == nil

      # Cleanup
      File.rm_rf!(dir)
    end

    test "returns path for existing page" do
      dir = Path.join(System.tmp_dir!(), "pdf_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "page-01.png"), "")

      result = PdfExtractor.page_image_path(dir, 1)
      assert result =~ "page-01.png"

      # Cleanup
      File.rm_rf!(dir)
    end
  end

  describe "extract_pages/3" do
    test "returns error for non-existent PDF" do
      dir = Path.join(System.tmp_dir!(), "pdf_out_#{:rand.uniform(100_000)}")

      result = PdfExtractor.extract_pages("/nonexistent.pdf", dir)

      assert {:error, _reason} = result
    end
  end

  describe "get_page_count/1" do
    test "returns error for non-existent PDF" do
      result = PdfExtractor.get_page_count("/nonexistent.pdf")

      assert {:error, _reason} = result
    end
  end
end
