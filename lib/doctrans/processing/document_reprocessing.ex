defmodule Doctrans.Processing.DocumentReprocessing do
  @moduledoc "Atomically replaces generated document content and starts a fresh run."
  import Ecto.Query
  alias Doctrans.Chat.Conversations
  alias Doctrans.Documents
  alias Doctrans.Documents.{Lifecycle, PageLifecycle, ProcessingStatus}
  alias Doctrans.Processing.{PageWork, Run}
  alias Doctrans.Repo

  # Whether an action may run is `ProcessingStatus`'s answer, read again under
  # the document lock: the viewer offered the control from the same answer, so
  # a refusal here is the state having moved since, never a second rule.

  @spec reprocess_document(Ecto.UUID.t(), keyword()) ::
          {:ok, Documents.Document.t()} | {:error, Doctrans.Errors.reason()}
  def reprocess_document(document_id, opts \\ []) do
    Repo.safe_transaction(fn ->
      document = Run.lock!(document_id)
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
    Conversations.forget_document(document.id)
  end

  defp requeue(document, opts), do: Repo.or_rollback(Run.replace(document, opts))

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

  defp do_reset_page(page, opts) do
    document = Run.lock!(page.document_id)
    current = Documents.get_page(page.id) || Repo.rollback(:page_not_found)
    validate_models!(opts)
    ensure_offered!(document, :reprocess_page)

    updated = restart_page(current, document, Run.choices(opts))
    {Repo.or_rollback(Lifecycle.resume(document)), updated}
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
    document = Run.lock!(document_id)
    validate_models!(opts)
    ensure_offered!(document, :retry_pages)

    pages = failed_pages(document_id)
    choices = Run.choices(opts)
    retried = Enum.map(pages, &restart_page(&1, document, choices))
    {Repo.or_rollback(Lifecycle.resume(document)), retried}
  end

  defp failed_pages(document_id) do
    document_id
    |> Documents.failed_pages_query()
    |> order_by([p], p.page_number)
    |> Repo.all()
  end

  # The per-page half of a reset and of a retry, under the caller's eligibility
  # check and document lock: start the page over, have Chat forget the page's
  # saved context, queue its run. The page's saved chunks are gone; leaving
  # their text in the conversation would answer the next question from the
  # content just discarded. The document lock also serializes this with
  # in-flight answers.
  #
  # The reset wrote the chosen models on the page, so the queued work carries
  # them. A job that already owns the page is a run still in flight, which the
  # eligibility check should have refused: the whole batch rolls back.
  defp restart_page(page, document, choices) do
    updated = Repo.or_rollback(PageLifecycle.reset(page, choices))
    :ok = Conversations.forget_page(document.id, page.id)

    case PageWork.queue(updated, document, as: :requested) do
      {:ok, :owned} -> Repo.rollback(:already_processing)
      {:ok, _queued} -> updated
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Each reset announced its page as the transaction committed; only the count
  # is left to report.
  defp count_retried({:ok, {_document, pages}}), do: {:ok, length(pages)}
  defp count_retried(error), do: error

  defp validate_models!(opts) do
    unless Enum.all?(Run.choices(opts), fn {_key, model} ->
             is_binary(model) && String.trim(model) != ""
           end),
           do: Repo.rollback(:invalid_model)
  end
end
