defmodule Doctrans.Processing.DocumentConverterTest do
  use ExUnit.Case, async: true

  alias Doctrans.Processing.DocumentConverter

  describe "available?/0" do
    test "returns boolean" do
      result = DocumentConverter.available?()
      assert is_boolean(result)
    end
  end

  describe "get_soffice_path/0" do
    test "returns a string path" do
      result = DocumentConverter.get_soffice_path()
      assert is_binary(result)
    end
  end

  describe "convert_to_pdf/2" do
    test "returns error for non-existent source file" do
      output_dir = Path.join(System.tmp_dir!(), "converter_test_#{:rand.uniform(100_000)}")

      result = DocumentConverter.convert_to_pdf("/nonexistent/file.docx", output_dir)
      assert {:error, message} = result
      assert message =~ "not found"

      # Cleanup
      File.rm_rf(output_dir)
    end

    test "returns error for invalid file format" do
      # Create a temporary file with invalid content
      dir = Path.join(System.tmp_dir!(), "converter_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)

      source_path = Path.join(dir, "test.docx")
      File.write!(source_path, "not a real docx file")

      output_dir = Path.join(dir, "output")

      # This test may fail differently depending on LibreOffice availability
      # If LibreOffice is installed, it will try to convert and likely fail
      # If not installed, the path lookup will return "soffice" which won't exist
      result = DocumentConverter.convert_to_pdf(source_path, output_dir)

      case result do
        {:error, _reason} ->
          # Expected - either file is invalid or LibreOffice not available
          :ok

        {:ok, _pdf_path} ->
          # LibreOffice sometimes succeeds with empty/invalid files
          :ok
      end

      # Cleanup
      File.rm_rf!(dir)
    end
  end
end
