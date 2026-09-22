defmodule Doctrans.Processing.DocumentReprocessing do
  @moduledoc "Atomically replaces generated document content and starts a fresh run."
  import Ecto.Query
  import Doctrans.Documents.Page, only: [failed?: 1]
  alias Doctrans.Chat.Session
  alias Doctrans.Documents
  alias Doctrans.Documents.{Page, Topics}
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob, RunCleanupJob}
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  # A run that has not produced its pages yet owns the whole document; there is
  # no per-page work to replace until it has.
  @queueing ~w(uploading queued extracting)
  # `cancelled` belongs here for the same reason `error` does: recovering from a
  # stop without deleting the document is the point of offering one.
  @reprocessable ~w(completed error cancelled)

  @spec reprocess_document(Ecto.UUID.t(), keyword()) ::
          {:ok, Documents.Document.t()} | {:error, Doctrans.Errors.reason()}
  def reprocess_document(document_id, opts \\ []) do
    transact(fn ->
      document = Run.lock(document_id) || Repo.rollback(:document_not_found)
      ensure_reprocessable!(document, opts)
      purge_generated_content(document)
      start_run(document, opts)
    end)
    |> publish()
  end

  defp ensure_reprocessable!(document, opts) do
    if Keyword.has_key?(opts, :expected_run_id) &&
         opts[:expected_run_id] != document.processing_run_id,
       do: Repo.rollback(:obsolete_run)

    validate_models!(opts)

    if document.status not in @reprocessable || Run.active?(document.id),
      do: Repo.rollback(:already_processing)

    unless Run.source_available?(document), do: Repo.rollback(:original_upload_missing)
  end

  defp purge_generated_content(document) do
    _ = from(p in Page, where: p.document_id == ^document.id) |> Repo.delete_all()

    _ =
      from(s in Session, where: s.document_id == ^document.id)
      |> Repo.update_all(set: [retrieved_context: []])

    :ok
  end

  defp start_run(document, opts) do
    attrs =
      Map.merge(Run.new_attrs(opts), %{status: "queued", total_pages: nil, error_message: nil})

    document = document |> Ecto.Changeset.change(attrs) |> Repo.update!()
    _ = insert!(DocumentExtractionJob.new(Run.args(document)))
    _ = insert!(RunCleanupJob.new(Run.args(document)))
    document
  end

  @spec reprocess_page(Ecto.UUID.t(), keyword()) ::
          {:ok, Page.t()} | {:error, Doctrans.Errors.reason()}
  def reprocess_page(page_id, opts \\ []) do
    case Documents.get_page(page_id) do
      nil -> {:error, :page_not_found}
      page -> reset_page(page, opts)
    end
  end

  defp reset_page(page, opts) do
    result = transact(fn -> do_reset_page(page, opts) end)

    case result do
      {:ok, {document, page}} ->
        _ = Topics.broadcast_document_updated(document)
        Topics.broadcast_page_updated(page)
        {:ok, page}

      error ->
        error
    end
  end

  # The page's saved chunks are gone; leaving their text in the conversation
  # context would answer the next question from the content just discarded.
  # The document lock held here also serializes this with in-flight answers.
  defp do_reset_page(page, opts) do
    document = Run.lock(page.document_id) || Repo.rollback(:document_not_found)
    current = Repo.get(Page, page.id) || Repo.rollback(:page_not_found)
    validate_models!(opts)

    if document.status in @queueing || Run.active?(document.id),
      do: Repo.rollback(:already_processing)

    {:ok, reset} = Documents.reset_page_for_reprocessing(current)
    _ = purge_page_context(document.id, current.id)

    choices = Run.choices(opts)
    updated = request_models(reset, choices)

    _ = insert!(LlmProcessingJob.new(page_job_args(page, updated, choices), priority: 1))
    {:ok, document} = Documents.update_document_status(document, "processing")
    {document, updated}
  end

  @doc """
  Queues a fresh attempt for the document's failed pages, and only those.

  One transaction and one eligibility check covers the batch: queueing the first
  page makes `Run.active?/1` true, so a loop over `reprocess_page/2` would
  refuse every page after it.
  """
  @spec retry_failed_pages(Ecto.UUID.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, Doctrans.Errors.reason()}
  def retry_failed_pages(document_id, opts \\ []) do
    transact(fn -> do_retry_failed_pages(document_id, opts) end) |> publish_retried()
  end

  defp do_retry_failed_pages(document_id, opts) do
    document = Run.lock(document_id) || Repo.rollback(:document_not_found)
    validate_models!(opts)

    if document.status in @queueing || Run.active?(document.id),
      do: Repo.rollback(:already_processing)

    pages = failed_pages(document_id)
    if pages == [], do: Repo.rollback(:nothing_to_retry)

    choices = Run.choices(opts)
    retried = Enum.map(pages, &retry_page(&1, document, choices))
    {:ok, document} = Documents.update_document_status(document, "processing")
    {document, retried}
  end

  # `Doctrans.Documents.Pages.failed_pages_query/1` assembles the same three
  # clauses, but naming that module here would put this one over the dependency
  # ceiling. The rule itself is not restated: `failed?/1` is the single
  # definition both queries are built from.
  defp failed_pages(document_id) do
    from(p in Page,
      where: p.document_id == ^document_id,
      where: failed?(p),
      order_by: p.page_number
    )
    |> Repo.all()
  end

  # The per-page half of `do_reset_page/2`, under the batch's single eligibility
  # check. Purging the page's saved context is as required here as it is there:
  # the chunks it quotes are discarded along with the content they described.
  defp retry_page(page, document, choices) do
    {:ok, reset} = Documents.reset_page_for_reprocessing(page)
    _ = purge_page_context(document.id, page.id)
    updated = request_models(reset, choices)
    _ = insert!(LlmProcessingJob.new(page_job_args(page, updated, choices), priority: 1))
    updated
  end

  defp publish_retried({:ok, {document, pages}}) do
    _ = Topics.broadcast_document_updated(document)
    Enum.each(pages, &Topics.broadcast_page_updated/1)
    {:ok, length(pages)}
  end

  defp publish_retried(error), do: error

  defp request_models(page, choices) do
    page
    |> Ecto.Changeset.change(
      requested_extraction_model: choices.extraction_model,
      requested_translation_model: choices.translation_model
    )
    |> Repo.update!()
  end

  defp page_job_args(page, updated, choices) do
    LlmProcessingJob.page_args(
      page,
      updated.processing_generation,
      LlmProcessingJob.model_args(Map.to_list(choices))
    )
  end

  defp purge_page_context(document_id, page_id) do
    from(s in Session, where: s.document_id == ^document_id, lock: "FOR UPDATE")
    |> Repo.all()
    |> Enum.each(fn session ->
      kept = Enum.reject(session.retrieved_context, &(&1["page_id"] == page_id))

      if length(kept) != length(session.retrieved_context) do
        Repo.update!(Ecto.Changeset.change(session, retrieved_context: kept))
      end
    end)
  end

  defp validate_models!(opts) do
    unless Enum.all?(Run.choices(opts), fn {_key, model} ->
             is_binary(model) && String.trim(model) != ""
           end),
           do: Repo.rollback(:invalid_model)
  end

  defp insert!(changeset) do
    case Oban.insert(changeset) do
      {:ok, %{conflict?: false} = job} -> job
      {:ok, _} -> Repo.rollback(:already_processing)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transact(fun) do
    Repo.transaction(fun) |> Doctrans.Errors.result()
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      {:error, {:database_error, [reason: error]}}
  end

  defp publish({:ok, document}) do
    _ = Topics.broadcast_document_updated(document)
    {:ok, document}
  end

  defp publish(error), do: error
end
