defmodule Doctrans.Documents.Revision do
  @moduledoc """
  Transactional guards that fence a write to a document or page behind the
  revision the caller loaded.

  A reprocess replaces a document's processing run, and a page reset advances
  the page's content revision or processing generation. A write planned
  against the old state must not land on the new one, so each guard locks the
  parent document row, compares the stored revision with the one the caller
  holds, and rolls back with `:obsolete_run` when they differ.

  These guards touch only `Doctrans.Repo`, `Doctrans.Documents.Document` and
  `Doctrans.Documents.Page`; the processing layer builds on them, never the
  other way round.
  """
  import Ecto.Query
  alias Doctrans.Documents.{Document, Page}
  alias Doctrans.Repo

  @doc "Locks the document row for the current transaction, or nil when it is gone."
  @spec lock(Ecto.UUID.t()) :: Document.t() | nil
  def lock(document_id) do
    from(d in Document, where: d.id == ^document_id, lock: "FOR UPDATE") |> Repo.one()
  end

  @doc "True when the document still belongs to the given processing run."
  @spec current?(Document.t() | nil, Ecto.UUID.t() | nil) :: boolean() | nil
  def current?(document, run_id), do: document && document.processing_run_id == run_id

  @doc """
  Runs `fun` on the locked document while it is still on the run the caller
  loaded, otherwise returns `{:error, :obsolete_run}`.
  """
  @spec with_current(Document.t(), (Document.t() -> result)) :: result | {:error, term()}
        when result: var
  def with_current(document, fun) do
    Repo.transaction(fn ->
      current = lock(document.id)

      if current?(current, document.processing_run_id),
        do: fun.(current),
        else: Repo.rollback(:obsolete_run)
    end)
    |> unwrap()
  end

  @doc """
  Runs `fun` on the locked page while its content revision and processing
  generation match the ones the caller loaded, otherwise returns
  `{:error, :obsolete_run}`.

  A full restart creates new page IDs. Locking the parent serializes page
  writes with replacement; checking the content revision also fences
  single-page resets.
  """
  @spec with_page(Page.t(), (Page.t() -> result)) :: result | {:error, term()} when result: var
  def with_page(page, fun) do
    Repo.transaction(fn ->
      document = lock(page.document_id)
      current = Repo.one(from p in Page, where: p.id == ^page.id, lock: "FOR UPDATE")

      if document && current && current.content_revision == page.content_revision &&
           current.processing_generation == page.processing_generation,
         do: fun.(current),
         else: Repo.rollback(:obsolete_run)
    end)
    |> unwrap()
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap(error), do: error
end
