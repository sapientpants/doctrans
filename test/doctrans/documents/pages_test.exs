defmodule Doctrans.Documents.PagesTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Documents.Page
  alias Doctrans.Documents.Pages

  import Doctrans.Fixtures

  describe "get_page!/1" do
    test "returns page with given id" do
      doc = document_fixture()
      page = page_fixture(doc)
      assert Pages.get_page!(page.id).id == page.id
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Pages.get_page!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_page_by_number/2" do
    test "returns page with given document_id and page_number" do
      doc = document_with_pages_fixture(%{}, 3)
      page = Pages.get_page_by_number(doc.id, 2)
      assert page.page_number == 2
      assert page.document_id == doc.id
    end

    test "returns nil for non-existent page" do
      doc = document_fixture()
      assert is_nil(Pages.get_page_by_number(doc.id, 999))
    end
  end

  describe "get_page_by_number!/2" do
    test "returns page with given document_id and page_number" do
      doc = document_with_pages_fixture(%{}, 3)
      page = Pages.get_page_by_number!(doc.id, 2)
      assert page.page_number == 2
    end

    test "raises for non-existent page" do
      doc = document_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Pages.get_page_by_number!(doc.id, 999)
      end
    end
  end

  describe "list_pages/1" do
    test "returns empty list when no pages" do
      doc = document_fixture()
      assert Pages.list_pages(doc.id) == []
    end

    test "returns all pages for document" do
      doc = document_with_pages_fixture(%{}, 3)
      pages = Pages.list_pages(doc.id)
      assert length(pages) == 3
    end

    test "orders pages by page_number" do
      doc = document_with_pages_fixture(%{}, 3)
      pages = Pages.list_pages(doc.id)
      page_numbers = Enum.map(pages, & &1.page_number)
      assert page_numbers == [1, 2, 3]
    end

    test "does not return pages from other documents" do
      doc1 = document_with_pages_fixture(%{title: "Doc 1"}, 2)
      doc2 = document_with_pages_fixture(%{title: "Doc 2"}, 3)

      pages1 = Pages.list_pages(doc1.id)
      pages2 = Pages.list_pages(doc2.id)

      assert length(pages1) == 2
      assert length(pages2) == 3
    end
  end

  describe "create_page/2" do
    test "creates page with valid attrs" do
      doc = document_fixture()

      attrs = %{
        page_number: 1,
        image_path: "test/path.png"
      }

      assert {:ok, %Page{} = page} = Pages.create_page(doc, attrs)
      assert page.page_number == 1
      assert page.image_path == "test/path.png"
      assert page.document_id == doc.id
      assert page.extraction_status == "pending"
      assert page.translation_status == "pending"
    end

    test "returns error for missing page_number" do
      doc = document_fixture()
      assert {:error, changeset} = Pages.create_page(doc, %{})
      assert %{page_number: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "create_pages/2" do
    test "creates multiple pages in bulk" do
      doc = document_fixture()

      page_attrs = [
        %{page_number: 1, image_path: "page_1.png"},
        %{page_number: 2, image_path: "page_2.png"},
        %{page_number: 3, image_path: "page_3.png"}
      ]

      {count, _} = Pages.create_pages(doc, page_attrs)
      assert count == 3

      pages = Pages.list_pages(doc.id)
      assert length(pages) == 3
    end

    test "sets default statuses" do
      doc = document_fixture()
      page_attrs = [%{page_number: 1, image_path: "page_1.png"}]

      Pages.create_pages(doc, page_attrs)

      [page] = Pages.list_pages(doc.id)
      assert page.extraction_status == "pending"
      assert page.translation_status == "pending"
    end
  end

  describe "update_page/2" do
    test "updates page with valid attrs" do
      doc = document_fixture()
      page = page_fixture(doc)

      assert {:ok, updated} = Pages.update_page(page, %{image_path: "new/path.png"})
      assert updated.image_path == "new/path.png"
    end

    test "validates extraction_status" do
      doc = document_fixture()
      page = page_fixture(doc)

      assert {:error, changeset} = Pages.update_page(page, %{extraction_status: "invalid"})
      assert %{extraction_status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "update_page_extraction/2" do
    test "updates extraction status and original markdown" do
      doc = document_fixture()
      page = page_fixture(doc)

      attrs = %{
        extraction_status: "completed",
        original_markdown: "# Test Content"
      }

      assert {:ok, updated} = Pages.update_page_extraction(page, attrs)
      assert updated.extraction_status == "completed"
      assert updated.original_markdown == "# Test Content"
    end

    test "validates extraction_status" do
      doc = document_fixture()
      page = page_fixture(doc)

      assert {:error, changeset} =
               Pages.update_page_extraction(page, %{extraction_status: "invalid"})

      assert %{extraction_status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "update_page_translation/2" do
    test "updates translation status and translated markdown" do
      doc = document_fixture()
      page = page_fixture(doc)

      attrs = %{
        translation_status: "completed",
        translated_markdown: "# Translated Content"
      }

      assert {:ok, updated} = Pages.update_page_translation(page, attrs)
      assert updated.translation_status == "completed"
      assert updated.translated_markdown == "# Translated Content"
    end

    test "validates translation_status" do
      doc = document_fixture()
      page = page_fixture(doc)

      assert {:error, changeset} =
               Pages.update_page_translation(page, %{translation_status: "invalid"})

      assert %{translation_status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "get_next_page_for_extraction/1" do
    test "returns first page with pending extraction" do
      doc = document_with_pages_fixture(%{}, 3)
      page = Pages.get_next_page_for_extraction(doc.id)
      assert page.page_number == 1
      assert page.extraction_status == "pending"
    end

    test "skips pages with completed extraction" do
      doc = document_with_pages_fixture(%{}, 3)
      [page1 | _] = Pages.list_pages(doc.id)

      {:ok, _} = Pages.update_page_extraction(page1, %{extraction_status: "completed"})

      page = Pages.get_next_page_for_extraction(doc.id)
      assert page.page_number == 2
    end

    test "returns nil when all pages extracted" do
      doc = document_with_pages_fixture(%{}, 2)

      for page <- Pages.list_pages(doc.id) do
        Pages.update_page_extraction(page, %{extraction_status: "completed"})
      end

      assert is_nil(Pages.get_next_page_for_extraction(doc.id))
    end
  end

  describe "get_next_page_for_translation/1" do
    test "returns first page with completed extraction and pending translation" do
      doc = document_with_pages_fixture(%{}, 3)
      [page1 | _] = Pages.list_pages(doc.id)

      {:ok, _} =
        Pages.update_page_extraction(page1, %{
          extraction_status: "completed",
          original_markdown: "test"
        })

      page = Pages.get_next_page_for_translation(doc.id)
      assert page.page_number == 1
    end

    test "does not return pages with pending extraction" do
      doc = document_with_pages_fixture(%{}, 3)
      assert is_nil(Pages.get_next_page_for_translation(doc.id))
    end

    test "returns nil when all pages translated" do
      doc = document_with_pages_fixture(%{}, 2)

      for page <- Pages.list_pages(doc.id) do
        {:ok, page} = Pages.update_page_extraction(page, %{extraction_status: "completed"})
        Pages.update_page_translation(page, %{translation_status: "completed"})
      end

      assert is_nil(Pages.get_next_page_for_translation(doc.id))
    end
  end

  describe "all_pages_completed?/1" do
    test "returns false when pages have pending translation" do
      doc = document_with_pages_fixture(%{}, 2)
      refute Pages.all_pages_completed?(doc.id)
    end

    test "returns true when all pages have completed translation" do
      doc = document_with_pages_fixture(%{}, 2)

      for page <- Pages.list_pages(doc.id) do
        {:ok, page} = Pages.update_page_extraction(page, %{extraction_status: "completed"})
        Pages.update_page_translation(page, %{translation_status: "completed"})
      end

      assert Pages.all_pages_completed?(doc.id)
    end

    test "returns true for document with no pages" do
      doc = document_fixture()
      assert Pages.all_pages_completed?(doc.id)
    end
  end
end
