defmodule Doctrans.Fixtures do
  @moduledoc """
  Test fixtures for creating documents and pages.
  """

  alias Doctrans.Documents
  alias Doctrans.Documents.Page
  alias Doctrans.Documents.Pages
  alias Doctrans.Repo

  @doc """
  Creates a document with valid attributes.
  """
  def document_fixture(attrs \\ %{}) do
    {:ok, document} =
      attrs
      |> Enum.into(%{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "en",
        status: "uploading"
      })
      |> Documents.create_document()

    document
  end

  @doc """
  Creates a document with pages.
  """
  def document_with_pages_fixture(attrs \\ %{}, page_count \\ 3) do
    document = document_fixture(Map.merge(%{total_pages: page_count}, attrs))

    page_attrs_list =
      Enum.map(1..page_count, fn page_num ->
        %{
          page_number: page_num,
          image_path: "documents/#{document.id}/pages/page_#{page_num}.png"
        }
      end)

    Pages.create_pages(document, page_attrs_list)

    Documents.get_document_with_pages!(document.id)
  end

  @doc """
  Creates a page for a document.
  """
  def page_fixture(document, attrs \\ %{}) do
    {:ok, page} =
      Pages.create_page(
        document,
        Enum.into(attrs, %{
          page_number: 1,
          image_path: "documents/#{document.id}/pages/page_1.png"
        })
      )

    page
  end

  @doc """
  Creates a completed, single-page document whose page carries an embedding, so
  the chat opens with a usable context.

  The embedding is inserted through `Repo` rather than the `Pages` API to pin a
  deterministic vector of the configured dimension.
  """
  def completed_document_with_embedding_fixture(attrs \\ %{}) do
    document =
      document_fixture(
        Enum.into(attrs, %{
          target_language: "de",
          status: "completed",
          total_pages: 1
        })
      )

    Repo.insert!(%Page{
      id: Ecto.UUID.generate(),
      document_id: document.id,
      page_number: 1,
      image_path: "documents/#{document.id}/pages/page_1.png",
      original_markdown: "Test content for chat",
      translated_markdown: "Testinhalt für Chat",
      extraction_status: "completed",
      translation_status: "completed",
      embedding_status: "completed",
      embedding: Pgvector.new(List.duplicate(0.1, 1024))
    })

    document
  end

  @doc """
  Creates a completed page (extraction and translation done).
  """
  def completed_page_fixture(document, attrs \\ %{}) do
    page = page_fixture(document, attrs)

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        original_markdown: "# Original Content\n\nSome text here."
      })

    {:ok, page} =
      Pages.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: "# Translated Content\n\nSome translated text."
      })

    page
  end
end
