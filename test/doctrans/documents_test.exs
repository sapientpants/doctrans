defmodule Doctrans.DocumentsTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents
  alias Doctrans.Documents.Document

  import Doctrans.Fixtures

  describe "list_documents/1" do
    test "returns empty list when no documents" do
      assert Documents.list_documents() == []
    end

    test "returns all documents with pages preloaded" do
      doc = document_fixture()
      [result] = Documents.list_documents()
      assert result.id == doc.id
      assert is_list(result.pages)
    end

    test "returns multiple documents" do
      _doc1 = document_fixture(%{title: "First"})
      _doc2 = document_fixture(%{title: "Second"})

      docs = Documents.list_documents()
      assert length(docs) == 2
    end

    test "accepts sort options" do
      _doc1 = document_fixture(%{title: "First"})
      _doc2 = document_fixture(%{title: "Second"})

      # Verify sorting doesn't error
      docs_desc = Documents.list_documents(sort_by: :inserted_at, sort_dir: :desc)
      docs_asc = Documents.list_documents(sort_by: :inserted_at, sort_dir: :asc)
      assert length(docs_desc) == 2
      assert length(docs_asc) == 2
    end

    test "sorts by title when specified" do
      doc_b = document_fixture(%{title: "Beta"})
      doc_a = document_fixture(%{title: "Alpha"})

      [first, second] = Documents.list_documents(sort_by: :title, sort_dir: :asc)
      assert first.id == doc_a.id
      assert second.id == doc_b.id
    end
  end

  describe "list_documents_with_progress/1" do
    test "returns documents with progress field" do
      _doc = document_with_pages_fixture(%{}, 2)
      [result] = Documents.list_documents_with_progress()
      assert Map.has_key?(result, :progress)
      assert result.progress == 0.0
    end

    test "calculates correct progress for completed pages" do
      doc = document_with_pages_fixture(%{}, 2)
      [page1 | _] = doc.pages

      # Complete extraction and translation for first page
      {:ok, page1} =
        Documents.update_page_extraction(page1, %{
          extraction_status: "completed",
          original_markdown: "test"
        })

      {:ok, _page1} =
        Documents.update_page_translation(page1, %{
          translation_status: "completed",
          translated_markdown: "test"
        })

      [result] = Documents.list_documents_with_progress()
      # 2 steps completed out of 4 total (2 pages * 2 steps each)
      assert result.progress == 50.0
    end
  end

  describe "get_document!/1" do
    test "returns document with given id" do
      doc = document_fixture()
      assert Documents.get_document!(doc.id).id == doc.id
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Documents.get_document!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_document/1" do
    test "returns document with given id" do
      doc = document_fixture()
      assert Documents.get_document(doc.id).id == doc.id
    end

    test "returns nil for non-existent id" do
      assert is_nil(Documents.get_document(Ecto.UUID.generate()))
    end
  end

  describe "get_document_with_pages!/1" do
    test "returns document with pages preloaded" do
      doc = document_with_pages_fixture(%{}, 3)
      result = Documents.get_document_with_pages!(doc.id)
      assert result.id == doc.id
      assert length(result.pages) == 3
    end

    test "pages are ordered by page_number" do
      doc = document_with_pages_fixture(%{}, 3)
      result = Documents.get_document_with_pages!(doc.id)
      page_numbers = Enum.map(result.pages, & &1.page_number)
      assert page_numbers == [1, 2, 3]
    end
  end

  describe "create_document/1" do
    test "creates document with valid attrs" do
      attrs = %{
        title: "New Document",
        original_filename: "new.pdf",
        target_language: "de"
      }

      assert {:ok, %Document{} = doc} = Documents.create_document(attrs)
      assert doc.title == "New Document"
      assert doc.original_filename == "new.pdf"
      assert doc.target_language == "de"
      assert doc.status == "uploading"
    end

    test "returns error changeset with invalid attrs" do
      assert {:error, changeset} = Documents.create_document(%{})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates status is a valid value" do
      attrs = %{
        title: "Test",
        original_filename: "test.pdf",
        target_language: "en",
        status: "invalid"
      }

      assert {:error, changeset} = Documents.create_document(attrs)
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "update_document/2" do
    test "updates document with valid attrs" do
      doc = document_fixture()
      assert {:ok, updated} = Documents.update_document(doc, %{title: "Updated Title"})
      assert updated.title == "Updated Title"
    end

    test "returns error changeset with invalid attrs" do
      doc = document_fixture()
      assert {:error, changeset} = Documents.update_document(doc, %{status: "invalid"})
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "update_document_status/3" do
    test "updates document status" do
      doc = document_fixture()
      assert {:ok, updated} = Documents.update_document_status(doc, "processing")
      assert updated.status == "processing"
    end

    test "updates status with error message" do
      doc = document_fixture()

      assert {:ok, updated} =
               Documents.update_document_status(doc, "error", "Something went wrong")

      assert updated.status == "error"
      assert updated.error_message == "Something went wrong"
    end

    test "rejects invalid status" do
      doc = document_fixture()
      assert {:error, changeset} = Documents.update_document_status(doc, "invalid_status")
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "delete_document/1" do
    test "deletes document" do
      doc = document_fixture()
      assert {:ok, _} = Documents.delete_document(doc)
      assert is_nil(Documents.get_document(doc.id))
    end

    test "cascades delete to pages" do
      doc = document_with_pages_fixture(%{}, 3)
      assert {:ok, _} = Documents.delete_document(doc)
      assert Documents.list_pages(doc.id) == []
    end

    test "deletes document when directory exists" do
      doc = document_fixture()
      # Create directory
      dir = Documents.document_upload_dir(doc.id)
      File.mkdir_p!(dir)

      assert {:ok, _} = Documents.delete_document(doc)
      refute File.exists?(dir)
    end

    test "deletes document when directory does not exist" do
      doc = document_fixture()
      # Don't create directory
      dir = Documents.document_upload_dir(doc.id)
      refute File.exists?(dir)

      assert {:ok, _} = Documents.delete_document(doc)
      assert is_nil(Documents.get_document(doc.id))
    end
  end

  describe "document_upload_dir/1" do
    test "returns correct path" do
      path = Documents.document_upload_dir("test-id")
      assert String.ends_with?(path, "documents/test-id")
    end
  end

  describe "document_pages_dir/1" do
    test "returns correct path" do
      path = Documents.document_pages_dir("test-id")
      assert String.ends_with?(path, "documents/test-id/pages")
    end
  end

  describe "ensure_document_dirs!/1" do
    test "creates directories and returns pages dir path" do
      path = Documents.ensure_document_dirs!("test-ensure-#{System.unique_integer()}")
      assert File.exists?(path)
      File.rm_rf!(Path.dirname(path))
    end
  end

  describe "calculate_progress/1" do
    test "returns 0.0 for document with no pages" do
      doc = document_fixture(%{total_pages: 0})
      assert Documents.calculate_progress(doc) == 0.0
    end

    test "returns 0.0 for document with nil total_pages" do
      doc = document_fixture()
      assert Documents.calculate_progress(doc) == 0.0
    end

    test "returns 0.0 for document with pending pages" do
      doc = document_with_pages_fixture(%{}, 2)
      assert Documents.calculate_progress(doc) == 0.0
    end

    test "returns 100.0 for fully completed document" do
      doc = document_fixture(%{total_pages: 1})
      page = page_fixture(doc, %{page_number: 1})

      {:ok, page} =
        Documents.update_page_extraction(page, %{
          extraction_status: "completed",
          original_markdown: "test"
        })

      {:ok, _page} =
        Documents.update_page_translation(page, %{
          translation_status: "completed",
          translated_markdown: "test"
        })

      doc = Documents.get_document!(doc.id)
      assert Documents.calculate_progress(doc) == 100.0
    end
  end

  describe "calculate_progress_preloaded/1" do
    test "calculates progress from preloaded pages" do
      doc = document_with_pages_fixture(%{}, 2)
      assert Documents.calculate_progress_preloaded(doc) == 0.0
    end

    test "falls back to calculate_progress if pages not preloaded" do
      doc = document_fixture(%{total_pages: 0})
      assert Documents.calculate_progress_preloaded(doc) == 0.0
    end
  end

  describe "PubSub functions" do
    test "subscribe_documents/0 subscribes to documents topic" do
      assert :ok = Documents.subscribe_documents()
    end

    test "subscribe_document/1 subscribes to document topic" do
      assert :ok = Documents.subscribe_document("test-id")
    end

    test "broadcast_document_update/1 broadcasts to subscribers" do
      doc = document_fixture()
      Documents.subscribe_document(doc.id)
      Documents.subscribe_documents()

      Documents.broadcast_document_update(doc)

      # Should receive on document topic
      assert_receive {:document_updated, ^doc}
      # Should also receive on general documents topic
      assert_receive {:document_updated, ^doc}
    end

    test "broadcast_page_update/1 broadcasts to subscribers" do
      doc = document_fixture()
      page = page_fixture(doc)
      Documents.subscribe_document(doc.id)
      Documents.subscribe_documents()

      Documents.broadcast_page_update(page)

      assert_receive {:page_updated, ^page}
      assert_receive {:page_updated, ^page}
    end
  end

  describe "uploads_dir/0" do
    test "returns configured upload directory" do
      dir = Documents.uploads_dir()
      assert is_binary(dir)
      assert String.contains?(dir, "uploads")
    end
  end

  describe "list_documents_with_progress/1 additional" do
    test "returns documents with calculated progress" do
      doc = document_with_pages_fixture(%{status: "processing"}, 2)
      [result] = Documents.list_documents_with_progress()
      assert result.id == doc.id
      assert Map.has_key?(result, :progress)
      assert result.progress == 0.0
    end
  end
end
