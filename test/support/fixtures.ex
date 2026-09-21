defmodule Doctrans.Fixtures do
  @moduledoc """
  Test fixtures for creating documents and pages.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Doctrans.Documents
  alias Doctrans.Documents.Page
  alias Doctrans.Documents.Pages
  alias Doctrans.Processing.Run
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
        source_language: "de",
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

    # Discarded deliberately: the document is reloaded with its pages below.
    _ = Pages.create_pages(document, page_attrs_list)

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
  Writes a placeholder source file where a processing run looks for the original.

  `Doctrans.Processing.Run.source_path/1` is the only path the extraction job
  reads from once a run exists, so a test that drives extraction has to put a
  file there. Returns that path and removes the document's upload directory when
  the test exits.
  """
  def document_source_fixture(document, contents \\ "%PDF-1.4\n") do
    path = Run.source_path(document)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf(Documents.document_upload_dir(document.id)) end)
    path
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
