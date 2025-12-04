defmodule Doctrans.Documents do
  @moduledoc """
  Context for managing documents and pages.

  Provides CRUD operations for documents and pages, including file cleanup
  when documents are deleted.
  """

  import Ecto.Query
  alias Doctrans.Repo
  alias Doctrans.Documents.{Document, Page}

  # ============================================================================
  # Documents
  # ============================================================================

  @doc """
  Returns the list of all documents, ordered by creation date (newest first).
  """
  def list_documents do
    Document
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single document by ID.

  Raises `Ecto.NoResultsError` if the Document does not exist.
  """
  def get_document!(id), do: Repo.get!(Document, id)

  @doc """
  Gets a single document by ID, returns nil if not found.
  """
  def get_document(id), do: Repo.get(Document, id)

  @doc """
  Gets a document with its pages preloaded.
  """
  def get_document_with_pages!(id) do
    Document
    |> Repo.get!(id)
    |> Repo.preload(pages: from(p in Page, order_by: p.page_number))
  end

  @doc """
  Creates a new document.
  """
  def create_document(attrs \\ %{}) do
    %Document{}
    |> Document.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a document.
  """
  def update_document(%Document{} = document, attrs) do
    document
    |> Document.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a document's status.
  """
  def update_document_status(%Document{} = document, status, error_message \\ nil) do
    document
    |> Document.status_changeset(status, error_message)
    |> Repo.update()
  end

  @doc """
  Deletes a document and all associated files.

  This will:
  1. Delete the document directory containing all page images
  2. Delete all page records (via cascade)
  3. Delete the document record
  """
  def delete_document(%Document{} = document) do
    # Delete files first
    document_dir = document_upload_dir(document.id)

    if File.exists?(document_dir) do
      File.rm_rf!(document_dir)
    end

    # Delete from database (pages cascade automatically)
    Repo.delete(document)
  end

  @doc """
  Returns the upload directory for a document.
  """
  def document_upload_dir(document_id) do
    Path.join([uploads_dir(), "documents", to_string(document_id)])
  end

  @doc """
  Returns the pages directory for a document.
  """
  def document_pages_dir(document_id) do
    Path.join([document_upload_dir(document_id), "pages"])
  end

  @doc """
  Returns the base uploads directory.
  """
  def uploads_dir do
    Application.get_env(:doctrans, :uploads)[:upload_dir] ||
      Path.expand("priv/static/uploads", Application.app_dir(:doctrans))
  end

  @doc """
  Ensures the document's upload directories exist.
  """
  def ensure_document_dirs!(document_id) do
    pages_dir = document_pages_dir(document_id)
    File.mkdir_p!(pages_dir)
    pages_dir
  end

  @doc """
  Calculates the progress percentage for a document.

  Returns a float between 0.0 and 100.0.
  """
  def calculate_progress(%Document{} = document) do
    document = Repo.preload(document, :pages)
    calculate_progress_from_pages(document.pages, document.total_pages)
  end

  defp calculate_progress_from_pages([], _total), do: 0.0
  defp calculate_progress_from_pages(_pages, nil), do: 0.0
  defp calculate_progress_from_pages(_pages, 0), do: 0.0

  defp calculate_progress_from_pages(pages, total_pages) do
    # Each page has 2 steps: extraction and translation
    total_steps = total_pages * 2

    completed_steps =
      Enum.reduce(pages, 0, fn page, acc ->
        extraction_done = if page.extraction_status == "completed", do: 1, else: 0
        translation_done = if page.translation_status == "completed", do: 1, else: 0
        acc + extraction_done + translation_done
      end)

    completed_steps / total_steps * 100.0
  end

  # ============================================================================
  # Pages
  # ============================================================================

  @doc """
  Gets a single page by ID.
  """
  def get_page!(id), do: Repo.get!(Page, id)

  @doc """
  Gets a page by document ID and page number.
  """
  def get_page_by_number(document_id, page_number) do
    Repo.get_by(Page, document_id: document_id, page_number: page_number)
  end

  @doc """
  Gets a page by document ID and page number, raises if not found.
  """
  def get_page_by_number!(document_id, page_number) do
    Repo.get_by!(Page, document_id: document_id, page_number: page_number)
  end

  @doc """
  Lists all pages for a document, ordered by page number.
  """
  def list_pages(document_id) do
    Page
    |> where([p], p.document_id == ^document_id)
    |> order_by([p], p.page_number)
    |> Repo.all()
  end

  @doc """
  Creates a new page for a document.
  """
  def create_page(%Document{} = document, attrs) do
    %Page{}
    |> Page.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:document, document)
    |> Repo.insert()
  end

  @doc """
  Creates multiple pages for a document in a single transaction.
  """
  def create_pages(%Document{} = document, page_attrs_list) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    pages =
      Enum.map(page_attrs_list, fn attrs ->
        %{
          id: Uniq.UUID.uuid7(),
          document_id: document.id,
          page_number: attrs.page_number,
          image_path: attrs.image_path,
          extraction_status: "pending",
          translation_status: "pending",
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Page, pages)
  end

  @doc """
  Updates a page.
  """
  def update_page(%Page{} = page, attrs) do
    page
    |> Page.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates extraction results for a page.
  """
  def update_page_extraction(%Page{} = page, attrs) do
    page
    |> Page.extraction_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates translation results for a page.
  """
  def update_page_translation(%Page{} = page, attrs) do
    page
    |> Page.translation_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets the next page that needs extraction.
  """
  def get_next_page_for_extraction(document_id) do
    Page
    |> where([p], p.document_id == ^document_id and p.extraction_status == "pending")
    |> order_by([p], p.page_number)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Gets the next page that needs translation.
  """
  def get_next_page_for_translation(document_id) do
    Page
    |> where([p], p.document_id == ^document_id)
    |> where([p], p.extraction_status == "completed" and p.translation_status == "pending")
    |> order_by([p], p.page_number)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Checks if all pages in a document are fully processed.
  """
  def all_pages_completed?(document_id) do
    incomplete_count =
      Page
      |> where([p], p.document_id == ^document_id)
      |> where([p], p.translation_status != "completed")
      |> Repo.aggregate(:count)

    incomplete_count == 0
  end

  # ============================================================================
  # PubSub
  # ============================================================================

  @doc """
  Subscribes to updates for all documents (for dashboard).
  """
  def subscribe_documents do
    Phoenix.PubSub.subscribe(Doctrans.PubSub, "documents")
  end

  @doc """
  Subscribes to updates for a specific document.
  """
  def subscribe_document(document_id) do
    Phoenix.PubSub.subscribe(Doctrans.PubSub, "document:#{document_id}")
  end

  @doc """
  Broadcasts a document update event.
  """
  def broadcast_document_update(%Document{} = document) do
    # Broadcast to specific document topic (for document viewer)
    Phoenix.PubSub.broadcast(
      Doctrans.PubSub,
      "document:#{document.id}",
      {:document_updated, document}
    )

    # Also broadcast to general documents topic (for dashboard)
    Phoenix.PubSub.broadcast(Doctrans.PubSub, "documents", {:document_updated, document})
  end

  @doc """
  Broadcasts a page update event.
  """
  def broadcast_page_update(%Page{} = page) do
    # Broadcast to specific document topic (for document viewer)
    Phoenix.PubSub.broadcast(
      Doctrans.PubSub,
      "document:#{page.document_id}",
      {:page_updated, page}
    )

    # Also broadcast to general documents topic (for dashboard progress)
    Phoenix.PubSub.broadcast(Doctrans.PubSub, "documents", {:page_updated, page})
  end
end
