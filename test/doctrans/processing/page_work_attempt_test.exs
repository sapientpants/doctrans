defmodule Doctrans.Processing.PageWorkAttemptTest do
  # The happy path of one page through both model stages. The failure paths,
  # and what becomes of the document on each, are `PageWorkRetryTest`'s.
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents
  alias Doctrans.Documents.Layout
  alias Doctrans.Documents.PageLifecycle
  alias Doctrans.Processing.PageWork

  import Doctrans.Fixtures

  describe "attempt/2" do
    test "processes page extraction and translation successfully" do
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{page_number: 1})
      setup_image_file(page)

      result = PageWork.attempt(page.id)

      assert result == :ok

      # Verify page is processed
      updated_page = Documents.get_page!(page.id)
      assert updated_page.extraction_status == "completed"
      assert updated_page.translation_status == "completed"
      assert updated_page.original_markdown != nil
      assert updated_page.translated_markdown != nil
    end

    test "only translates if extraction already complete" do
      document = document_fixture(%{status: "processing"})
      page = page_fixture(document, %{page_number: 1})

      # Mark extraction as completed
      {:ok, page} =
        PageLifecycle.complete(page, :extraction, %{markdown: "# Test Content"})

      result = PageWork.attempt(page.id)

      assert result == :ok

      updated_page = Documents.get_page!(page.id)
      assert updated_page.extraction_status == "completed"
      assert updated_page.original_markdown == "# Test Content"
      assert updated_page.translation_status == "completed"
      assert updated_page.translated_markdown != nil
    end

    test "cancels for a non-existent page" do
      fake_id = Ecto.UUID.generate()

      result = PageWork.attempt(fake_id)

      assert {:cancel, :page_not_found} = result
    end
  end

  # The image file extraction hands to the model, where the page says it is.
  defp setup_image_file(page) do
    full_path = Path.join(Layout.root(), page.image_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, "fake image")
    on_exit(fn -> File.rm(full_path) end)
  end
end
