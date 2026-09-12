defmodule Doctrans.Documents.Pages do
  @moduledoc """
  Context for managing document pages.

  Provides CRUD operations and queries for pages within documents.
  """

  import Ecto.Query
  import Doctrans.Documents.Page, only: [failed?: 1]

  alias Doctrans.Documents.{Document, Page}
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  @doc """
  Gets a single page by ID, returns nil if not found.
  """
  def get_page(id), do: Repo.get(Page, id)

  @doc """
  Gets a single page by ID, raises if not found.
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
  Returns `%{page_id => {content_revision, translated_markdown}}` for the given ids.

  Ids that are not UUIDs and pages that no longer exist are absent from the map,
  so a caller can read a missing key as "no such page" without pre-validating.
  """
  @spec page_content_state([term()]) :: %{
          optional(Ecto.UUID.t()) => {integer(), String.t() | nil}
        }
  def page_content_state(page_ids) do
    case castable_ids(page_ids) do
      [] ->
        %{}

      ids ->
        from(p in Page,
          where: p.id in ^ids,
          select: {p.id, {p.content_revision, p.translated_markdown}}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  defp castable_ids(page_ids) do
    page_ids
    |> Enum.flat_map(fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> [id]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Creates a new page for a document.
  """
  def create_page(document, attrs) do
    %Page{}
    |> Page.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:document, document)
    |> Repo.insert()
    |> Doctrans.Errors.result()
  end

  @doc """
  Creates multiple pages for a document in a single transaction.
  """
  def create_pages(document, page_attrs_list) do
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
    |> Doctrans.Errors.result()
  end

  @doc """
  Updates extraction results for a page.
  """
  def update_page_extraction(%Page{} = page, attrs) do
    Run.with_page(page, fn current ->
      current
      |> Page.extraction_changeset(attrs)
      |> Repo.update()
      |> Doctrans.Errors.result()
    end)
  end

  @doc """
  Updates translation results for a page.
  """
  def update_page_translation(%Page{} = page, attrs) do
    Run.with_page(page, fn current ->
      current
      |> Page.translation_changeset(attrs)
      |> Repo.update()
      |> Doctrans.Errors.result()
    end)
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
  Returns the terminal outcome of a document's pages.

  Documents with an unknown or non-positive page count, or with pages missing,
  are never terminal.

  - `:completed` - every expected page finished translation successfully
  - `:failed` - every expected page settled and at least one stage failed
  - `:incomplete` - work is still outstanding (pending, processing, or missing)

  A failed page is terminal for its own content only; whether the document may
  still recover depends on retries, which callers resolve separately.
  """
  @spec completion_state(Uniq.UUID.t()) :: :completed | :failed | :incomplete
  def completion_state(document_id) do
    case page_counts(document_id) do
      %{total_pages: total, pages: total, succeeded: total} ->
        :completed

      %{total_pages: total, pages: total, succeeded: succeeded, failed: failed}
      when succeeded + failed == total ->
        :failed

      _ ->
        :incomplete
    end
  end

  @doc """
  Lists the page numbers whose extraction or translation failed, in page order.
  """
  @spec failed_page_numbers(Uniq.UUID.t()) :: [integer()]
  def failed_page_numbers(document_id) do
    document_id
    |> failed_pages_query()
    |> order_by([p], p.page_number)
    |> select([p], p.page_number)
    |> Repo.all()
  end

  @doc """
  Query for the pages of a document whose extraction or translation failed.
  """
  @spec failed_pages_query(Uniq.UUID.t()) :: Ecto.Query.t()
  def failed_pages_query(document_id) do
    Page
    |> where([p], p.document_id == ^document_id)
    |> where([p], failed?(p))
  end

  # Success and failure stay disjoint so settled pages add up to the expected total.
  defp page_counts(document_id) do
    Document
    |> where([d], d.id == ^document_id and d.total_pages > 0)
    |> join(:inner, [d], p in Page, on: p.document_id == d.id)
    |> group_by([d], [d.id, d.total_pages])
    |> select([d, p], %{
      total_pages: d.total_pages,
      pages: count(p.id),
      succeeded: filter(count(p.id), p.translation_status == "completed"),
      failed: filter(count(p.id), failed?(p))
    })
    |> Repo.one()
  end

  @doc """
  Resets a page for reprocessing.

  Clears extracted and translated content and resets all statuses to pending.
  Uses `Ecto.Changeset.change/2` to directly update all fields including
  embedding fields that aren't in the standard changeset.
  """
  def reset_page_for_reprocessing(%Page{} = page) do
    page
    |> Ecto.Changeset.change(%{
      processing_generation: Uniq.UUID.uuid7(),
      extraction_model: nil,
      translation_model: nil,
      original_markdown: nil,
      translated_markdown: nil,
      extraction_status: "pending",
      translation_status: "pending",
      embedding: nil,
      embedding_status: "pending"
    })
    |> Repo.update()
    |> Doctrans.Errors.result()
  end
end
