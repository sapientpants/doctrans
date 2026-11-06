defmodule Doctrans.Documents do
  @moduledoc """
  The documents context: the one entry point for document and page records.

  Hosts the document CRUD (with file cleanup on delete), the dashboard's
  `Summary` listing and its ordering helper, and the page operations, which are
  implemented in `Doctrans.Documents.Pages` and reached through the delegates
  below. Callers name this module rather than `Pages` so the page API has a
  single path; `Pages` is addressed directly only by its own tests.

  Chat readiness (`embeddings_ready?/1`) is not part of this context: its only
  consumer is `Doctrans.Chat`, which reaches `Pages` for it. Nor is the
  document's status: every status write is a named transition of
  `Doctrans.Documents.Lifecycle`, and processing moves a page's stages only
  through one of `Doctrans.Documents.PageLifecycle`.

  The module sits at Credo's first-party dependency ceiling, so a new
  collaborator has to displace one.
  """
  require Logger

  import Ecto.Query

  alias Doctrans.Documents.{Document, Layout, Page, Pages, Revision, Summary, Topics}
  alias Doctrans.Repo
  alias Doctrans.Validation

  # Page operations live in `Doctrans.Documents.Pages`; these delegates are the
  # entry points callers reach them through.
  defdelegate get_page(id), to: Pages
  defdelegate get_page!(id), to: Pages
  defdelegate get_page_by_number(document_id, page_number), to: Pages
  defdelegate get_page_by_number!(document_id, page_number), to: Pages
  defdelegate list_pages(document_id), to: Pages
  defdelegate page_content_state(page_ids), to: Pages
  defdelegate create_page(document, attrs), to: Pages
  defdelegate update_page(page, attrs), to: Pages
  defdelegate completion_state(document_id), to: Pages
  defdelegate failed_page_numbers(document_id), to: Pages
  defdelegate failed_pages_query(document_id), to: Pages
  defdelegate reset_page_for_reprocessing(page), to: Pages
  defdelegate delete_pages(document_id), to: Pages

  # ============================================================================
  # Documents
  # ============================================================================

  @doc """
  Returns the list of all documents with optional sorting.

  Pages are not loaded: a caller that needs them reaches for
  `get_document_with_pages/1`, and the dashboard reads
  `list_documents_with_progress/1`, which selects only the page fields progress
  needs.

  ## Options

  - `:sort_by` - Field to sort by: `:inserted_at` (default) or `:title`
  - `:sort_dir` - Sort direction: `:desc` (default) or `:asc`
  """
  @spec list_documents(keyword()) :: [Document.t()]
  def list_documents(opts \\ []) do
    Document
    |> ordered_documents(opts)
    |> Repo.all()
  end

  @doc """
  Returns `Doctrans.Documents.Summary` structs with progress pre-calculated.
  Useful for dashboard views that need to display progress.

  Only the page fields required for progress are loaded (in one query),
  avoiding loading every page's markdown content into memory. Documents
  with no pages yet are treated as 0% progress.

  Supports `:sort_by` and `:sort_dir`, plus `:document_ids` to refresh only
  affected cards. Optional `:limit` and `:offset` bound the document query
  and its associated page query for paginated callers.
  """
  @spec list_documents_with_progress(keyword()) :: [Summary.t()]
  def list_documents_with_progress(opts \\ []) do
    documents =
      Document
      |> ordered_documents(opts)
      |> filter_document_ids(opts)
      |> limit_documents(opts)
      |> offset(^Keyword.get(opts, :offset, 0))
      |> Repo.all()

    pages_by_document =
      documents
      |> Enum.map(& &1.id)
      |> progress_pages()
      |> Enum.group_by(& &1.document_id)

    Enum.map(documents, fn document ->
      Summary.new(document, Map.get(pages_by_document, document.id, []))
    end)
  end

  defp filter_document_ids(query, opts) do
    case Keyword.fetch(opts, :document_ids) do
      {:ok, ids} -> where(query, [d], d.id in ^ids)
      :error -> query
    end
  end

  defp limit_documents(query, opts) do
    case Keyword.fetch(opts, :limit) do
      {:ok, count} -> limit(query, ^count)
      :error -> query
    end
  end

  # Load only the page fields needed for progress, in a single query,
  # instead of preloading every page's full markdown content.
  defp progress_pages([]), do: []

  defp progress_pages(document_ids) do
    from(p in Page,
      where: p.document_id in ^document_ids,
      # Only the fields needed for progress + the first-page thumbnail;
      # the heavy markdown fields are not selected
      select: %{
        id: p.id,
        document_id: p.document_id,
        page_number: p.page_number,
        extraction_status: p.extraction_status,
        translation_status: p.translation_status,
        image_path: p.image_path
      },
      order_by: [p.document_id, p.page_number]
    )
    |> Repo.all()
  end

  @doc """
  Sorts `{id, sort_key}` pairs using the database's ordering semantics.

  Supports the same `:sort_by` and `:sort_dir` options as summary queries. Sorts
  only the supplied snapshot so unrelated, unhandled changes cannot reorder
  dashboard cards. No document rows or pages are loaded.
  """
  @spec sort_document_order([{Ecto.UUID.t(), term()}], keyword()) :: [{Ecto.UUID.t(), term()}]
  def sort_document_order(entries, opts \\ [])
  def sort_document_order([], _opts), do: []

  def sort_document_order(entries, opts) do
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    rows = Enum.map(entries, fn {id, key} -> %{sort_by => key, :id => id} end)

    from(d in values(rows, Document))
    |> ordered_documents(opts)
    |> select([d], {d.id, field(d, ^sort_by)})
    |> Repo.all()
  end

  defp ordered_documents(query, opts) do
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)
    order_by(query, ^[{sort_dir, sort_by}, {sort_dir, :id}])
  end

  @doc """
  Gets a single document by ID.

  Raises `Ecto.NoResultsError` if the Document does not exist.
  """
  @spec get_document!(Ecto.UUID.t()) :: Document.t()
  def get_document!(id), do: Repo.get!(Document, id)

  @doc """
  Gets a single document by ID, returns nil if not found or the ID is invalid.
  """
  @spec get_document(String.t()) :: Document.t() | nil
  def get_document(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Document, id)
      :error -> nil
    end
  end

  @doc """
  Gets a document with ordered pages, or nil for a missing or invalid ID.
  """
  @spec get_document_with_pages(String.t()) :: Document.t() | nil
  def get_document_with_pages(id) do
    id
    |> get_document()
    |> Repo.preload(pages: from(p in Page, order_by: p.page_number))
  end

  @doc """
  Creates a document with validation.
  """
  @spec create_document(map()) :: {:ok, Document.t()} | {:error, Doctrans.Errors.reason()}
  def create_document(attrs \\ %{}) do
    with {:ok, validated_attrs} <- Validation.validate_document_attrs(attrs),
         {:ok, document} <-
           %Document{}
           |> Document.changeset(validated_attrs)
           |> Repo.insert()
           |> Doctrans.Errors.result() do
      # Announce the new document on the collection topic every open dashboard
      # subscribes to, so an upload made in one tab appears in the others.
      _ = Topics.broadcast_document_created(document)
      {:ok, document}
    end
  end

  @doc """
  Updates a document's own attributes: title, filename and languages. Its
  status is `Lifecycle`'s and its page count is `set_total_pages/2`'s.
  """
  @spec update_document(Document.t(), map()) ::
          {:ok, Document.t()} | {:error, Doctrans.Errors.reason()}
  def update_document(%Document{} = document, attrs) do
    Revision.with_current(document, fn current ->
      current
      |> Document.changeset(attrs)
      |> Repo.update()
      |> Doctrans.Errors.result()
    end)
  end

  @doc """
  Records the page count extraction found for the document's current run, and
  announces it once committed, so a viewer can show progress before the first
  page lands.

  The one write to `total_pages` outside `Lifecycle.requeue/2`, which clears
  it when a run starts; the general changeset does not cast it.
  """
  @spec set_total_pages(Document.t(), non_neg_integer()) ::
          {:ok, Document.t()} | {:error, Doctrans.Errors.reason()}
  def set_total_pages(%Document{} = document, total_pages)
      when is_integer(total_pages) and total_pages >= 0 do
    Revision.with_current(document, fn current ->
      current
      |> Ecto.Changeset.change(total_pages: total_pages)
      |> Repo.update()
      |> Doctrans.Errors.result()
    end)
    |> announce_updated()
  end

  @doc """
  Records the source language detected for the document, unless one is already
  on the row.

  Pages of one document translate concurrently, so two of them can find the
  column empty and both detect. The write is conditional on it still being
  empty, so exactly one lands, and the row is then read back: the write that
  won answers `{:claimed, document}` and is announced once committed; one that
  lost answers `{:lost, document}` holding the winner's language, which is
  what every page translates from. A row that is gone answers `{:lost, nil}`.
  """
  @spec claim_source_language(Document.t(), String.t()) ::
          {:claimed, Document.t()} | {:lost, Document.t() | nil}
  def claim_source_language(%Document{id: id}, language) when is_binary(language) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {claimed, _} =
      from(d in Document, where: d.id == ^id and is_nil(d.source_language))
      |> Repo.update_all(set: [source_language: language, updated_at: now])

    case {claimed, Repo.get(Document, id)} do
      {1, %Document{} = stored} ->
        {:claimed, _} = announce_updated({:claimed, stored})

      {_, stored} ->
        {:lost, stored}
    end
  end

  defp announce_updated({tag, %Document{} = document} = result) when tag in [:ok, :claimed] do
    _ = Repo.after_commit(fn -> Topics.broadcast_document_updated(document) end)
    result
  end

  defp announce_updated(result), do: result

  @doc """
  Deletes a document and all associated files.

  Succeeds if the document was already removed after it was loaded.

  This will:
  1. Delete the document directory containing all page images
  2. Delete all page records (via cascade)
  3. Delete the document record
  """
  # The directory comes from the persisted document UUID and configured upload root;
  # the File calls themselves live in delete_locked_document/1.
  @spec delete_document(Document.t()) :: {:ok, Document.t()} | {:error, Doctrans.Errors.reason()}
  def delete_document(%Document{} = document) do
    result =
      Repo.transaction(fn ->
        _ = Revision.lock(document.id)
        delete_locked_document(document)
      end)
      |> case do
        {:ok, result} -> result
        error -> Doctrans.Errors.result(error)
      end

    # Broadcast only after the transaction has committed: announcing from inside
    # it would advertise a deletion a rollback could still undo, and would reach
    # subscribers before the row was actually gone.
    case result do
      {:ok, deleted} ->
        _ = Topics.broadcast_document_deleted(deleted)
        {:ok, deleted}

      error ->
        error
    end
  end

  # Fixed document directory under configured uploads, serialized with restarts.
  # sobelow_skip ["Traversal.FileModule"]
  defp delete_locked_document(document) do
    # Delete files first (best-effort; a failure here must not prevent the
    # database row from being removed)
    document_dir = Layout.document_dir(document.id)

    if File.exists?(document_dir) do
      Logger.info("Deleting document files at #{document_dir}")

      # Best-effort: a failure here must not prevent the database row from
      # being removed.
      case File.rm_rf(document_dir) do
        {:ok, _files} ->
          :ok

        {:error, reason, _path} ->
          Logger.error("Failed to delete document files at #{document_dir}: #{inspect(reason)}")
      end
    end

    # Delete from database (pages cascade automatically)
    Repo.delete(document, allow_stale: true) |> Doctrans.Errors.result()
  end
end
