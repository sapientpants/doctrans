defmodule Doctrans.Processing.LlmProcessorTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Documents
  alias Doctrans.Documents.Pages
  alias Doctrans.Processing.LlmProcessor

  import Doctrans.Fixtures

  describe "process_page/2" do
    test "processes page extraction and translation successfully" do
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{page_number: 1})

      # Create the image file for the mock to find
      upload_dir = Documents.uploads_dir()
      full_path = Path.join(upload_dir, page.image_path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, "fake image")

      result = LlmProcessor.process_page(page.id, MapSet.new())

      assert result == :ok

      # Verify page is processed
      updated_page = Documents.get_page!(page.id)
      assert updated_page.extraction_status == "completed"
      assert updated_page.translation_status == "completed"
      assert updated_page.original_markdown != nil
      assert updated_page.translated_markdown != nil
    end

    test "skips pages from cancelled documents" do
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{page_number: 1})
      cancelled = MapSet.new([document.id])

      result = LlmProcessor.process_page(page.id, cancelled)

      assert result == :ok

      # Page status should not change
      updated_page = Documents.get_page!(page.id)
      assert updated_page.extraction_status == "pending"
    end

    test "skips already completed page" do
      document = document_fixture(%{status: "processing"})
      page = completed_page_fixture(document, %{page_number: 1})

      result = LlmProcessor.process_page(page.id, MapSet.new())

      assert result == :ok
    end

    test "only translates if extraction already complete" do
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{page_number: 1})

      # Mark extraction as completed
      {:ok, page} =
        Pages.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "# Test Content"
        })

      result = LlmProcessor.process_page(page.id, MapSet.new())

      assert result == :ok

      updated_page = Documents.get_page!(page.id)
      assert updated_page.extraction_status == "completed"
      assert updated_page.translation_status == "completed"
      assert updated_page.translated_markdown != nil
    end

    test "returns error for non-existent page" do
      fake_id = Ecto.UUID.generate()

      result = LlmProcessor.process_page(fake_id, MapSet.new())

      assert {:error, _} = result
    end
  end

  describe "extraction error handling" do
    setup do
      on_exit(fn ->
        Application.delete_env(:doctrans, :ollama_stub_extraction_error)
        Application.delete_env(:doctrans, :ollama_stub_translation_error)
      end)

      :ok
    end

    test "fails immediately on circuit breaker open" do
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{page_number: 1})

      # Create the image file
      setup_image_file(page)

      # Configure stub to return circuit open error
      Application.put_env(:doctrans, :ollama_stub_extraction_error, :circuit_open)

      result = LlmProcessor.process_page(page.id, MapSet.new())

      assert {:error, _} = result

      # Verify page is marked as error
      updated_page = Documents.get_page!(page.id)
      assert updated_page.extraction_status == "error"
    end

    test "fails immediately on permanent error" do
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{page_number: 1})

      setup_image_file(page)

      # Configure stub to return permanent error (404)
      Application.put_env(:doctrans, :ollama_stub_extraction_error, "HTTP 404: Model not found")

      result = LlmProcessor.process_page(page.id, MapSet.new())

      assert {:error, _} = result

      updated_page = Documents.get_page!(page.id)
      assert updated_page.extraction_status == "error"
    end
  end

  describe "translation error handling" do
    setup do
      on_exit(fn ->
        Application.delete_env(:doctrans, :ollama_stub_extraction_error)
        Application.delete_env(:doctrans, :ollama_stub_translation_error)
      end)

      :ok
    end

    test "fails immediately on circuit breaker open during translation" do
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{page_number: 1})

      setup_image_file(page)

      # Configure stub: extraction succeeds, translation fails
      Application.put_env(:doctrans, :ollama_stub_translation_error, :circuit_open)

      result = LlmProcessor.process_page(page.id, MapSet.new())

      assert {:error, _} = result

      updated_page = Documents.get_page!(page.id)
      assert updated_page.extraction_status == "completed"
      assert updated_page.translation_status == "error"
    end

    test "fails immediately on permanent error during translation" do
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{page_number: 1})

      setup_image_file(page)

      # Configure stub: extraction succeeds, translation returns permanent error
      Application.put_env(:doctrans, :ollama_stub_translation_error, "HTTP 400: Invalid request")

      result = LlmProcessor.process_page(page.id, MapSet.new())

      assert {:error, _} = result

      updated_page = Documents.get_page!(page.id)
      assert updated_page.extraction_status == "completed"
      assert updated_page.translation_status == "error"
    end
  end

  # Helper to create a fake image file for tests
  defp setup_image_file(page) do
    upload_dir = Documents.uploads_dir()
    full_path = Path.join(upload_dir, page.image_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, "fake image")
  end
end
