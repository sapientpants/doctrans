defmodule Doctrans.Documents do
  @moduledoc """
  Context for managing books and pages.

  Provides CRUD operations for books and pages, including file cleanup
  when books are deleted.
  """

  import Ecto.Query
  alias Doctrans.Repo
  alias Doctrans.Documents.{Book, Page}

  # ============================================================================
  # Books
  # ============================================================================

  @doc """
  Returns the list of all books, ordered by creation date (newest first).
  """
  def list_books do
    Book
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single book by ID.

  Raises `Ecto.NoResultsError` if the Book does not exist.
  """
  def get_book!(id), do: Repo.get!(Book, id)

  @doc """
  Gets a single book by ID, returns nil if not found.
  """
  def get_book(id), do: Repo.get(Book, id)

  @doc """
  Gets a book with its pages preloaded.
  """
  def get_book_with_pages!(id) do
    Book
    |> Repo.get!(id)
    |> Repo.preload(pages: from(p in Page, order_by: p.page_number))
  end

  @doc """
  Creates a new book.
  """
  def create_book(attrs \\ %{}) do
    %Book{}
    |> Book.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a book.
  """
  def update_book(%Book{} = book, attrs) do
    book
    |> Book.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a book's status.
  """
  def update_book_status(%Book{} = book, status, error_message \\ nil) do
    book
    |> Book.status_changeset(status, error_message)
    |> Repo.update()
  end

  @doc """
  Deletes a book and all associated files.

  This will:
  1. Delete the book directory containing all page images
  2. Delete all page records (via cascade)
  3. Delete the book record
  """
  def delete_book(%Book{} = book) do
    # Delete files first
    book_dir = book_upload_dir(book.id)

    if File.exists?(book_dir) do
      File.rm_rf!(book_dir)
    end

    # Delete from database (pages cascade automatically)
    Repo.delete(book)
  end

  @doc """
  Returns the upload directory for a book.
  """
  def book_upload_dir(book_id) do
    Path.join([uploads_dir(), "books", to_string(book_id)])
  end

  @doc """
  Returns the pages directory for a book.
  """
  def book_pages_dir(book_id) do
    Path.join([book_upload_dir(book_id), "pages"])
  end

  @doc """
  Returns the base uploads directory.
  """
  def uploads_dir do
    Application.get_env(:doctrans, :uploads)[:upload_dir] ||
      Path.expand("priv/static/uploads", Application.app_dir(:doctrans))
  end

  @doc """
  Ensures the book's upload directories exist.
  """
  def ensure_book_dirs!(book_id) do
    pages_dir = book_pages_dir(book_id)
    File.mkdir_p!(pages_dir)
    pages_dir
  end

  @doc """
  Calculates the progress percentage for a book.

  Returns a float between 0.0 and 100.0.
  """
  def calculate_progress(%Book{} = book) do
    book = Repo.preload(book, :pages)
    calculate_progress_from_pages(book.pages, book.total_pages)
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
  Gets a page by book ID and page number.
  """
  def get_page_by_number(book_id, page_number) do
    Repo.get_by(Page, book_id: book_id, page_number: page_number)
  end

  @doc """
  Gets a page by book ID and page number, raises if not found.
  """
  def get_page_by_number!(book_id, page_number) do
    Repo.get_by!(Page, book_id: book_id, page_number: page_number)
  end

  @doc """
  Lists all pages for a book, ordered by page number.
  """
  def list_pages(book_id) do
    Page
    |> where([p], p.book_id == ^book_id)
    |> order_by([p], p.page_number)
    |> Repo.all()
  end

  @doc """
  Creates a new page for a book.
  """
  def create_page(%Book{} = book, attrs) do
    %Page{}
    |> Page.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:book, book)
    |> Repo.insert()
  end

  @doc """
  Creates multiple pages for a book in a single transaction.
  """
  def create_pages(%Book{} = book, page_attrs_list) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    pages =
      Enum.map(page_attrs_list, fn attrs ->
        %{
          id: Uniq.UUID.uuid7(),
          book_id: book.id,
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
  def get_next_page_for_extraction(book_id) do
    Page
    |> where([p], p.book_id == ^book_id and p.extraction_status == "pending")
    |> order_by([p], p.page_number)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Gets the next page that needs translation.
  """
  def get_next_page_for_translation(book_id) do
    Page
    |> where([p], p.book_id == ^book_id)
    |> where([p], p.extraction_status == "completed" and p.translation_status == "pending")
    |> order_by([p], p.page_number)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Checks if all pages in a book are fully processed.
  """
  def all_pages_completed?(book_id) do
    incomplete_count =
      Page
      |> where([p], p.book_id == ^book_id)
      |> where([p], p.translation_status != "completed")
      |> Repo.aggregate(:count)

    incomplete_count == 0
  end

  # ============================================================================
  # PubSub
  # ============================================================================

  @doc """
  Subscribes to updates for a specific book.
  """
  def subscribe_book(book_id) do
    Phoenix.PubSub.subscribe(Doctrans.PubSub, "book:#{book_id}")
  end

  @doc """
  Broadcasts a book update event.
  """
  def broadcast_book_update(%Book{} = book) do
    Phoenix.PubSub.broadcast(Doctrans.PubSub, "book:#{book.id}", {:book_updated, book})
  end

  @doc """
  Broadcasts a page update event.
  """
  def broadcast_page_update(%Page{} = page) do
    Phoenix.PubSub.broadcast(
      Doctrans.PubSub,
      "book:#{page.book_id}",
      {:page_updated, page}
    )
  end
end
