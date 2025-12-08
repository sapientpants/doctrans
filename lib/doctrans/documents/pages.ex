defmodule Doctrans.Documents.Pages do
  @moduledoc """
  Context for managing document pages.

  Provides CRUD operations and queries for pages within documents.
  """

  import Ecto.Query

  alias Doctrans.Documents.Page
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
  Creates a new page for a document.
  """
  def create_page(document, attrs) do
    %Page{}
    |> Page.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:document, document)
    |> Repo.insert()
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

  A page is considered "done" if:
  - translation_status = "completed", OR
  - extraction_status = "error" (can't translate without successful extraction)
  """
  def all_pages_completed?(document_id) do
    incomplete_count =
      Page
      |> where([p], p.document_id == ^document_id)
      |> where([p], p.translation_status != "completed" and p.extraction_status != "error")
      |> Repo.aggregate(:count)

    incomplete_count == 0
  end

  @doc """
  Resets a page for reprocessing.

  Clears extracted and translated content and resets all statuses to pending.
  """
  def reset_page_for_reprocessing(%Page{} = page) do
    page
    |> Page.changeset(%{
      original_markdown: nil,
      translated_markdown: nil,
      extraction_status: "pending",
      translation_status: "pending",
      embedding: nil,
      embedding_status: "pending"
    })
    |> Repo.update()
  end
end
