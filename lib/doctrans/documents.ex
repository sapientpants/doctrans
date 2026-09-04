defmodule Doctrans.Documents do
  @moduledoc """
  Context for managing documents.

  Provides CRUD operations for documents, including file cleanup
  when documents are deleted. For page operations, see `Doctrans.Documents.Pages`.
  """
  require Logger

  import Ecto.Query

  alias Doctrans.Documents.{Document, Page, Pages}
  alias Doctrans.Repo
  alias Doctrans.Validation

  # Delegate page operations for backward compatibility
  defdelegate get_page(id), to: Pages
  defdelegate get_page!(id), to: Pages
  defdelegate get_page_by_number(document_id, page_number), to: Pages
  defdelegate get_page_by_number!(document_id, page_number), to: Pages
  defdelegate list_pages(document_id), to: Pages
  defdelegate create_page(document, attrs), to: Pages
  defdelegate create_pages(document, page_attrs_list), to: Pages
  defdelegate update_page(page, attrs), to: Pages
  defdelegate update_page_extraction(page, attrs), to: Pages
  defdelegate update_page_translation(page, attrs), to: Pages
  defdelegate get_next_page_for_extraction(document_id), to: Pages
  defdelegate get_next_page_for_translation(document_id), to: Pages
  defdelegate all_pages_completed?(document_id), to: Pages
  defdelegate reset_page_for_reprocessing(page), to: Pages

  # ============================================================================
  # Documents
  # ============================================================================

  @doc """
  Returns the list of all documents with optional sorting.

  ## Options

  - `:sort_by` - Field to sort by: `:inserted_at` (default) or `:title`
  - `:sort_dir` - Sort direction: `:desc` (default) or `:asc`
  """
  def list_documents(opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)

    order = [{sort_dir, sort_by}]

    Document
    |> order_by(^order)
    |> Repo.all()
    |> Repo.preload(pages: from(p in Page, order_by: p.page_number))
  end

  @doc """
  Returns all documents with progress pre-calculated.
  Useful for dashboard views that need to display progress.

  Only the page fields required for progress are loaded (in one query),
  avoiding loading every page's markdown content into memory. Documents
  with no pages yet are treated as 0% progress.
  """
  def list_documents_with_progress(opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)

    order = [{sort_dir, sort_by}]

    documents =
      Document
      |> order_by(^order)
      |> Repo.all()

    document_ids = Enum.map(documents, & &1.id)

    # Load only the page fields needed for progress, in a single query,
    # instead of preloading every page's full markdown content.
    pages =
      if document_ids == [] do
        []
      else
        query =
          from(p in Page,
            where: p.document_id in ^document_ids,
            # Only the fields needed for progress; the rest are nil
            select: %Page{
              id: p.id,
              document_id: p.document_id,
              page_number: p.page_number,
              extraction_status: p.extraction_status,
              translation_status: p.translation_status
            },
            order_by: [p.document_id, p.page_number]
          )

        Repo.all(query)
      end

    pages_by_document = Enum.group_by(pages, & &1.document_id)

    Enum.map(documents, fn document ->
      pages = Map.get(pages_by_document, document.id, [])
      progress = calculate_progress_preloaded(%{document | pages: pages})

      document
      |> Map.put(:pages, pages)
      |> Map.put(:progress, progress)
    end)
  end

  @doc """
  Lists documents that need processing (status is "processing" or "queued").
  Used by Worker for startup recovery.
  """
  def list_incomplete_documents do
    Document
    |> where([d], d.status in ["processing", "queued"])
    |> order_by([d], asc: d.inserted_at)
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
  Creates a document with validation.
  """
  def create_document(attrs \\ %{}) do
    case Validation.validate_document_attrs(attrs) do
      {:ok, validated_attrs} ->
        %Document{}
        |> Document.changeset(validated_attrs)
        |> Repo.insert()
        |> case do
          {:ok, document} ->
            {:ok, document}

          {:error, changeset} ->
            {:error, changeset}
        end

      {:error, reason} when is_binary(reason) ->
        %Document{}
        |> Document.changeset(%{})
        |> Ecto.Changeset.add_error(:base, reason)
        |> Ecto.Changeset.apply_action(:insert)
    end
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
    # Delete files first (best-effort; a failure here must not prevent the
    # database row from being removed)
    document_dir = document_upload_dir(document.id)

    if File.exists?(document_dir) do
      Logger.info("Deleting document files at #{document_dir}")

      try do
        File.rm_rf(document_dir)
      rescue
        e ->
          Logger.error("Failed to delete document files at #{document_dir}: #{inspect(e)}")
      end
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

  @doc """
  Calculates progress from already-loaded pages (no DB query).
  Use this when pages are already preloaded to avoid N+1 queries.
  """
  def calculate_progress_preloaded(%Document{pages: pages, total_pages: total_pages})
      when is_list(pages) do
    calculate_progress_from_pages(pages, total_pages)
  end

  def calculate_progress_preloaded(%Document{} = document) do
    # Fallback if pages not preloaded
    calculate_progress(document)
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

  def unsubscribe_document(document_id) do
    Phoenix.PubSub.unsubscribe(Doctrans.PubSub, "document:#{document_id}")
  end

  @doc """
  Broadcasts a document update event.
  """
  def broadcast_document_update(%Document{} = document) do
    Logger.debug("Broadcasting document_updated for #{document.id} to documents topic")

    # Broadcast to specific document topic (for document viewer)
    _ =
      Phoenix.PubSub.broadcast(
        Doctrans.PubSub,
        "document:#{document.id}",
        {:document_updated, document}
      )

    # Also broadcast to general documents topic (for dashboard)
    _ = Phoenix.PubSub.broadcast(Doctrans.PubSub, "documents", {:document_updated, document})
  end

  @doc """
  Broadcasts a page update event.
  """
  def broadcast_page_update(%Page{} = page) do
    Logger.debug(
      "Broadcasting page_updated for page #{page.page_number} of document #{page.document_id}"
    )

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
