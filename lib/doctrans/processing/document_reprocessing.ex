defmodule Doctrans.Processing.DocumentReprocessing do
  @moduledoc "Atomically replaces generated document content and starts a fresh run."
  import Ecto.Query
  alias Doctrans.Chat.Session
  alias Doctrans.Documents
  alias Doctrans.Documents.{Lifecycle, Topics}
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob, RunCleanupJob}
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  # Every status rule here is `Lifecycle`'s: `reprocessable?/1` is the check a
  # fresh run needs, and `pre_processing?/1` says a run has not produced its
  # pages yet, so there is no per-page work to replace. `reprocess_document/2`
  # also requires that no run is active and that the original upload is still
  # on disk, which a caller cannot know without the lock.

  @spec reprocess_document(Ecto.UUID.t(), keyword()) ::
          {:ok, Documents.Document.t()} | {:error, Doctrans.Errors.reason()}
  def reprocess_document(document_id, opts \\ []) do
    Repo.safe_transaction(fn ->
      document = Run.lock(document_id) || Repo.rollback(:document_not_found)
      ensure_reprocessable!(document, opts)
      purge_generated_content(document)
      requeue(document, opts)
    end)
    |> Topics.publish_document_updated()
  end

  defp ensure_reprocessable!(document, opts) do
    if Keyword.has_key?(opts, :expected_run_id) &&
         opts[:expected_run_id] != document.processing_run_id,
       do: Repo.rollback(:obsolete_run)

    validate_models!(opts)

    if not Lifecycle.reprocessable?(document) || Run.active?(document.id),
      do: Repo.rollback(:already_processing)

    unless Run.source_available?(document), do: Repo.rollback(:original_upload_missing)
  end

  defp purge_generated_content(document) do
    _ = Documents.delete_pages(document.id)

    _ =
      from(s in Session, where: s.document_id == ^document.id)
      |> Repo.update_all(set: [retrieved_context: []])

    :ok
  end

  defp requeue(document, opts) do
    document = or_rollback(Lifecycle.requeue(document, Run.new_attrs(opts)))
    _ = document |> Run.args() |> DocumentExtractionJob.new() |> Repo.insert_job!()
    _ = document |> Run.args() |> RunCleanupJob.new() |> Repo.insert_job!()
    document
  end

  @spec reprocess_page(Ecto.UUID.t(), keyword()) ::
          {:ok, Documents.Page.t()} | {:error, Doctrans.Errors.reason()}
  def reprocess_page(page_id, opts \\ []) do
    case Documents.get_page(page_id) do
      nil -> {:error, :page_not_found}
      page -> reset_page(page, opts)
    end
  end

  defp reset_page(page, opts) do
    result = Repo.safe_transaction(fn -> do_reset_page(page, opts) end)

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
    current = Documents.get_page(page.id) || Repo.rollback(:page_not_found)
    validate_models!(opts)

    if Lifecycle.pre_processing?(document) || Run.active?(document.id),
      do: Repo.rollback(:already_processing)

    {:ok, reset} = Documents.reset_page_for_reprocessing(current)
    _ = purge_page_context(document.id, current.id)

    choices = Run.choices(opts)
    updated = request_models(reset, choices)

    _ =
      page
      |> page_job_args(updated, choices)
      |> LlmProcessingJob.new(priority: 1)
      |> Repo.insert_job!()

    {or_rollback(Lifecycle.resume(document)), updated}
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
    Repo.safe_transaction(fn -> do_retry_failed_pages(document_id, opts) end) |> publish_retried()
  end

  defp do_retry_failed_pages(document_id, opts) do
    document = Run.lock(document_id) || Repo.rollback(:document_not_found)
    validate_models!(opts)

    if Lifecycle.pre_processing?(document) || Run.active?(document.id),
      do: Repo.rollback(:already_processing)

    pages = failed_pages(document_id)
    if pages == [], do: Repo.rollback(:nothing_to_retry)

    choices = Run.choices(opts)
    retried = Enum.map(pages, &retry_page(&1, document, choices))
    {or_rollback(Lifecycle.resume(document)), retried}
  end

  defp failed_pages(document_id) do
    document_id
    |> Documents.failed_pages_query()
    |> order_by([p], p.page_number)
    |> Repo.all()
  end

  # The per-page half of `do_reset_page/2`, under the batch's single eligibility
  # check. Purging the page's saved context is as required here as it is there:
  # the chunks it quotes are discarded along with the content they described.
  defp retry_page(page, document, choices) do
    {:ok, reset} = Documents.reset_page_for_reprocessing(page)
    _ = purge_page_context(document.id, page.id)
    updated = request_models(reset, choices)

    _ =
      page
      |> page_job_args(updated, choices)
      |> LlmProcessingJob.new(priority: 1)
      |> Repo.insert_job!()

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

  # The eligibility check above ran under the same lock, so a refusal here is a
  # rule the two disagree on; rolling it back reports it rather than hiding it.
  defp or_rollback({:ok, document}), do: document
  defp or_rollback({:error, reason}), do: Repo.rollback(reason)
end
