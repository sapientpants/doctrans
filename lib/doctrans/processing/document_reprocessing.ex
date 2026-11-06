defmodule Doctrans.Processing.DocumentReprocessing do
  @moduledoc "Atomically replaces generated document content and starts a fresh run."
  import Ecto.Query
  alias Doctrans.Chat.Session
  alias Doctrans.Documents
  alias Doctrans.Documents.{Lifecycle, PageLifecycle, ProcessingStatus}
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  # Whether an action may run is `ProcessingStatus`'s answer, read again under
  # the document lock: the viewer offered the control from the same answer, so
  # a refusal here is the state having moved since, never a second rule.

  @spec reprocess_document(Ecto.UUID.t(), keyword()) ::
          {:ok, Documents.Document.t()} | {:error, Doctrans.Errors.reason()}
  def reprocess_document(document_id, opts \\ []) do
    Repo.safe_transaction(fn ->
      document = Run.lock(document_id) || Repo.rollback(:document_not_found)
      ensure_reprocessable!(document, opts)
      purge_generated_content(document)
      requeue(document, opts)
    end)
  end

  defp ensure_reprocessable!(document, opts) do
    if Keyword.has_key?(opts, :expected_run_id) &&
         opts[:expected_run_id] != document.processing_run_id,
       do: Repo.rollback(:obsolete_run)

    validate_models!(opts)
    ensure_offered!(document, :reprocess_document)
  end

  defp ensure_offered!(document, action) do
    case ProcessingStatus.for_document(document).actions[action] do
      :offered -> :ok
      {:refused, reason} -> Repo.rollback(reason)
    end
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
    _ = Run.enqueue(document, cleanup: true)
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

  # The reset announces the page itself once the transaction commits.
  defp reset_page(page, opts) do
    case Repo.safe_transaction(fn -> do_reset_page(page, opts) end) do
      {:ok, {_document, page}} -> {:ok, page}
      error -> error
    end
  end

  # The page's saved chunks are gone; leaving their text in the conversation
  # context would answer the next question from the content just discarded.
  # The document lock held here also serializes this with in-flight answers.
  defp do_reset_page(page, opts) do
    document = Run.lock(page.document_id) || Repo.rollback(:document_not_found)
    current = Documents.get_page(page.id) || Repo.rollback(:page_not_found)
    validate_models!(opts)
    ensure_offered!(document, :reprocess_page)

    choices = Run.choices(opts)
    updated = or_rollback(PageLifecycle.reset(current, choices))
    _ = purge_page_context(document.id, current.id)

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
  page puts work in flight, so a loop over `reprocess_page/2` would refuse
  every page after it.
  """
  @spec retry_failed_pages(Ecto.UUID.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, Doctrans.Errors.reason()}
  def retry_failed_pages(document_id, opts \\ []) do
    Repo.safe_transaction(fn -> do_retry_failed_pages(document_id, opts) end) |> count_retried()
  end

  defp do_retry_failed_pages(document_id, opts) do
    document = Run.lock(document_id) || Repo.rollback(:document_not_found)
    validate_models!(opts)
    ensure_offered!(document, :retry_pages)

    pages = failed_pages(document_id)
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
    updated = or_rollback(PageLifecycle.reset(page, choices))
    _ = purge_page_context(document.id, page.id)

    _ =
      page
      |> page_job_args(updated, choices)
      |> LlmProcessingJob.new(priority: 1)
      |> Repo.insert_job!()

    updated
  end

  # Each reset announced its page as the transaction committed; only the count
  # is left to report.
  defp count_retried({:ok, {_document, pages}}), do: {:ok, length(pages)}
  defp count_retried(error), do: error

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
